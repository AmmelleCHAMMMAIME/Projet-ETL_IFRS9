/* ============================================================================
   COUCHE STAGING (RAW) — Ingestion brute multi-sources
   Projet : ETL Risque de Crédit — IFRS 9 / ECL
   Principe : aucune transformation, typage souple, traçabilité totale
   ============================================================================ */

CREATE SCHEMA staging;
GO

/* ---- Métadonnées d'ingestion communes à toutes les tables staging ----
   source_system   : système d'origine (CORE_BANKING, BUREAU_CREDIT, MACRO_ECO...)
   batch_id        : identifiant du run ETL (FK vers etl.etl_run_log)
   load_ts         : horodatage d'ingestion
   is_processed    : flag de consommation par la couche cleansed
*/

CREATE TABLE staging.stg_customers (
    row_id              BIGINT IDENTITY(1,1) PRIMARY KEY,
    customer_source_id  NVARCHAR(50)    NOT NULL,
    full_name           NVARCHAR(200)   NULL,
    birth_date          NVARCHAR(20)    NULL,   -- brut : formats hétérogènes possibles
    national_id         NVARCHAR(50)    NULL,
    segment             NVARCHAR(50)    NULL,   -- Retail / SME / Corporate
    country_code        NVARCHAR(10)    NULL,
    onboarding_date     NVARCHAR(20)    NULL,
    source_system       NVARCHAR(50)    NOT NULL DEFAULT 'CORE_BANKING',
    batch_id            BIGINT          NOT NULL,
    load_ts             DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    is_processed        BIT             NOT NULL DEFAULT 0
);

CREATE TABLE staging.stg_accounts (
    row_id              BIGINT IDENTITY(1,1) PRIMARY KEY,
    account_source_id   NVARCHAR(50)    NOT NULL,
    customer_source_id  NVARCHAR(50)    NOT NULL,
    product_code        NVARCHAR(30)    NULL,
    branch_code          NVARCHAR(20)    NULL,
    opening_date         NVARCHAR(20)    NULL,
    credit_limit          NVARCHAR(30)    NULL,   -- brut, converti en NUMERIC en cleansed
    interest_rate         NVARCHAR(20)    NULL,
    currency               NVARCHAR(10)    NULL,
    parent_group_id        NVARCHAR(50)    NULL,   -- pour la hiérarchie d'exposition groupe
    source_system        NVARCHAR(50)    NOT NULL DEFAULT 'CORE_BANKING',
    batch_id              BIGINT          NOT NULL,
    load_ts                DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    is_processed           BIT             NOT NULL DEFAULT 0
);

CREATE TABLE staging.stg_transactions (
    row_id              BIGINT IDENTITY(1,1) PRIMARY KEY,
    transaction_id       NVARCHAR(50)    NOT NULL,
    account_source_id    NVARCHAR(50)    NOT NULL,
    transaction_date     NVARCHAR(20)    NULL,
    amount                NVARCHAR(30)    NULL,
    transaction_type      NVARCHAR(30)    NULL,   -- REPAYMENT / DRAWDOWN / FEE / INTEREST
    dpd_snapshot           NVARCHAR(10)    NULL,   -- days past due au moment de la transaction
    source_system        NVARCHAR(50)    NOT NULL DEFAULT 'CORE_BANKING',
    batch_id              BIGINT          NOT NULL,
    load_ts                DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    is_processed           BIT             NOT NULL DEFAULT 0
);

CREATE TABLE staging.stg_credit_bureau (
    row_id              BIGINT IDENTITY(1,1) PRIMARY KEY,
    customer_source_id  NVARCHAR(50)    NOT NULL,
    bureau_score          NVARCHAR(10)    NULL,
    external_default_flag NVARCHAR(5)     NULL,
    inquiry_count_12m      NVARCHAR(10)    NULL,
    report_date            NVARCHAR(20)    NULL,
    source_system        NVARCHAR(50)    NOT NULL DEFAULT 'BUREAU_CREDIT',
    batch_id              BIGINT          NOT NULL,
    load_ts                DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    is_processed           BIT             NOT NULL DEFAULT 0
);

CREATE TABLE staging.stg_macro_indicators (
    row_id              BIGINT IDENTITY(1,1) PRIMARY KEY,
    period_date          NVARCHAR(20)    NOT NULL,
    country_code          NVARCHAR(10)    NOT NULL,
    gdp_growth             NVARCHAR(20)    NULL,
    unemployment_rate       NVARCHAR(20)    NULL,
    inflation_rate           NVARCHAR(20)    NULL,
    policy_rate               NVARCHAR(20)    NULL,
    scenario_tag               NVARCHAR(30)    NULL,   -- BASELINE / UPSIDE / DOWNSIDE
    source_system        NVARCHAR(50)    NOT NULL DEFAULT 'MACRO_ECO',
    batch_id              BIGINT          NOT NULL,
    load_ts                DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    is_processed           BIT             NOT NULL DEFAULT 0
);

CREATE INDEX ix_stg_customers_batch ON staging.stg_customers(batch_id, is_processed);
CREATE INDEX ix_stg_accounts_batch  ON staging.stg_accounts(batch_id, is_processed);
CREATE INDEX ix_stg_transactions_batch ON staging.stg_transactions(batch_id, is_processed);
GO
