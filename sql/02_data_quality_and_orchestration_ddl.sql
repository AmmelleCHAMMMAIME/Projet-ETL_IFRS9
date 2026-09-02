/* ============================================================================
   GOUVERNANCE DE LA DONNÉE : qualité, quarantaine, journalisation ETL
   Cette couche est le cœur "recherche" du projet : elle rend le pipeline
   auditable et reproductible — exigence clé pour un usage doctoral/réglementaire.
   ============================================================================ */

CREATE SCHEMA etl;
GO
CREATE SCHEMA dq;
GO

-- Journal des exécutions ETL (traçabilité complète, un run = un batch_id)
CREATE TABLE etl.etl_run_log (
    batch_id        BIGINT IDENTITY(1,1) PRIMARY KEY,
    pipeline_name   NVARCHAR(100)   NOT NULL,
    started_at      DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    ended_at        DATETIME2       NULL,
    status          NVARCHAR(20)    NOT NULL DEFAULT 'RUNNING',  -- RUNNING/SUCCESS/FAILED
    rows_ingested   BIGINT          NULL,
    rows_quarantined BIGINT         NULL,
    error_message   NVARCHAR(MAX)   NULL
);

-- Journal détaillé par étape (staging -> cleansed -> curated -> feature mart)
CREATE TABLE etl.etl_step_log (
    step_log_id     BIGINT IDENTITY(1,1) PRIMARY KEY,
    batch_id        BIGINT          NOT NULL REFERENCES etl.etl_run_log(batch_id),
    step_name       NVARCHAR(100)   NOT NULL,
    started_at      DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    ended_at        DATETIME2       NULL,
    row_count       BIGINT          NULL,
    status          NVARCHAR(20)    NOT NULL DEFAULT 'RUNNING'
);

-- Règles de qualité déclaratives (permet d'ajouter des règles sans redéployer le code)
CREATE TABLE dq.dq_rules (
    rule_id         INT IDENTITY(1,1) PRIMARY KEY,
    target_table    NVARCHAR(100)   NOT NULL,
    target_column   NVARCHAR(100)   NULL,
    rule_type       NVARCHAR(50)    NOT NULL,  -- NOT_NULL / RANGE / REGEX / REFERENTIAL / FRESHNESS
    rule_expression NVARCHAR(500)   NULL,
    severity        NVARCHAR(20)    NOT NULL DEFAULT 'ERROR',  -- ERROR bloque, WARNING journalise
    is_active       BIT             NOT NULL DEFAULT 1
);

-- Quarantaine générique : toute ligne rejetée par une règle DQ y est stockée
-- avec sa charge utile brute (JSON) pour investigation sans perte d'information.
CREATE TABLE dq.dq_quarantine (
    quarantine_id   BIGINT IDENTITY(1,1) PRIMARY KEY,
    batch_id        BIGINT          NOT NULL,
    source_table    NVARCHAR(100)   NOT NULL,
    source_row_id   BIGINT          NOT NULL,
    rule_id         INT             NULL REFERENCES dq.dq_rules(rule_id),
    failure_reason  NVARCHAR(500)   NOT NULL,
    raw_payload     NVARCHAR(MAX)   NULL,   -- JSON de la ligne rejetée
    quarantined_at  DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    is_resolved     BIT             NOT NULL DEFAULT 0
);

-- Table de suivi de dérive statistique (data drift) entre deux fenêtres temporelles
-- Composante différenciante pour un positionnement doctoral (monitoring de la stabilité
-- des distributions utilisées en entrée des modèles PD/LGD/EAD).
CREATE TABLE dq.dq_drift_metrics (
    drift_id            BIGINT IDENTITY(1,1) PRIMARY KEY,
    batch_id            BIGINT          NOT NULL,
    feature_name        NVARCHAR(100)   NOT NULL,
    reference_period     NVARCHAR(20)    NOT NULL,
    current_period        NVARCHAR(20)    NOT NULL,
    reference_mean         FLOAT           NULL,
    current_mean            FLOAT           NULL,
    population_stability_index FLOAT       NULL,   -- PSI : métrique standard en risque de crédit
    drift_flag              BIT             NOT NULL DEFAULT 0,
    computed_at              DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME()
);

-- Quelques règles de qualité de départ
INSERT INTO dq.dq_rules (target_table, target_column, rule_type, rule_expression, severity)
VALUES
 ('stg_customers', 'customer_source_id', 'NOT_NULL', NULL, 'ERROR'),
 ('stg_accounts',  'credit_limit',        'RANGE',    '>= 0', 'ERROR'),
 ('stg_transactions','dpd_snapshot',       'RANGE',    '>= 0 AND <= 999', 'WARNING'),
 ('stg_credit_bureau','bureau_score',      'RANGE',    'BETWEEN 0 AND 1000', 'ERROR');
GO
