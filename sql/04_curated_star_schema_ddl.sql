/* ============================================================================
   COUCHE CURATED — Star schema pour l'analytique risque de crédit
   Dimensions en SCD Type 2 (historisation complète des changements d'attributs)
   Faits alimentant le moteur ECL (IFRS 9)
   ============================================================================ */

CREATE SCHEMA curated;
GO

/* ---------------------------- DIMENSIONS ---------------------------- */

CREATE TABLE curated.dim_date (
    date_key        INT             NOT NULL PRIMARY KEY,   -- format YYYYMMDD
    full_date         DATE            NOT NULL,
    [year]              INT             NOT NULL,
    [quarter]             INT             NOT NULL,
    [month]                 INT             NOT NULL,
    month_name               NVARCHAR(20)    NOT NULL,
    is_reporting_period_end    BIT             NOT NULL DEFAULT 0
);

-- SCD Type 2 : chaque changement d'attribut crée une nouvelle version
CREATE TABLE curated.dim_customer (
    customer_key         BIGINT IDENTITY(1,1) PRIMARY KEY,   -- clé de substitution
    customer_source_id     NVARCHAR(50)    NOT NULL,          -- clé naturelle
    full_name                 NVARCHAR(200)   NOT NULL,
    segment                     NVARCHAR(50)    NOT NULL,
    country_code                  NVARCHAR(10)    NOT NULL,
    bureau_score_band                NVARCHAR(20)    NULL,       -- ex: '700-750'
    effective_date                     DATETIME2       NOT NULL,
    expiry_date                          DATETIME2       NOT NULL DEFAULT '9999-12-31',
    is_current                             BIT             NOT NULL DEFAULT 1,
    version_number                           INT             NOT NULL DEFAULT 1
);
CREATE INDEX ix_dim_customer_natural ON curated.dim_customer(customer_source_id, is_current);

CREATE TABLE curated.dim_product (
    product_key     INT IDENTITY(1,1) PRIMARY KEY,
    product_code      NVARCHAR(30)    NOT NULL UNIQUE,
    product_name        NVARCHAR(100)   NOT NULL,
    product_family        NVARCHAR(50)    NOT NULL,   -- Mortgage / Consumer / SME / Corporate
    is_secured               BIT             NOT NULL DEFAULT 0
);

CREATE TABLE curated.dim_branch (
    branch_key      INT IDENTITY(1,1) PRIMARY KEY,
    branch_code       NVARCHAR(20)    NOT NULL UNIQUE,
    branch_name         NVARCHAR(100)   NOT NULL,
    region                 NVARCHAR(50)    NOT NULL,
    country_code             NVARCHAR(10)    NOT NULL
);

CREATE TABLE curated.dim_macro_scenario (
    scenario_key    INT IDENTITY(1,1) PRIMARY KEY,
    scenario_tag      NVARCHAR(30)    NOT NULL,   -- BASELINE / UPSIDE / DOWNSIDE
    scenario_weight     NUMERIC(5,4)    NOT NULL,   -- pondération macro-économique IFRS9
    valid_from             DATE            NOT NULL,
    valid_to                 DATE            NOT NULL DEFAULT '9999-12-31'
);

/* ------------------------------ FAITS -------------------------------- */

-- Fait d'exposition mensuel (snapshot) : base du calcul EAD
CREATE TABLE curated.fact_exposure (
    exposure_key        BIGINT IDENTITY(1,1) PRIMARY KEY,
    date_key               INT             NOT NULL REFERENCES curated.dim_date(date_key),
    customer_key             BIGINT          NOT NULL REFERENCES curated.dim_customer(customer_key),
    product_key                INT             NOT NULL REFERENCES curated.dim_product(product_key),
    branch_key                   INT             NOT NULL REFERENCES curated.dim_branch(branch_key),
    scenario_key                   INT             NOT NULL REFERENCES curated.dim_macro_scenario(scenario_key),
    outstanding_balance               NUMERIC(18,2)   NOT NULL,
    credit_limit                        NUMERIC(18,2)   NOT NULL,
    dpd_current                           INT             NOT NULL DEFAULT 0,
    ifrs9_stage                             TINYINT         NOT NULL DEFAULT 1,  -- 1/2/3 selon détérioration du risque
    batch_id                                  BIGINT          NOT NULL
);
CREATE INDEX ix_fact_exposure_date ON curated.fact_exposure(date_key);
CREATE INDEX ix_fact_exposure_customer ON curated.fact_exposure(customer_key);

-- Fait des événements de défaut / retard (granularité transaction)
CREATE TABLE curated.fact_credit_event (
    event_key         BIGINT IDENTITY(1,1) PRIMARY KEY,
    date_key             INT             NOT NULL REFERENCES curated.dim_date(date_key),
    customer_key           BIGINT          NOT NULL REFERENCES curated.dim_customer(customer_key),
    product_key              INT             NOT NULL REFERENCES curated.dim_product(product_key),
    event_type                 NVARCHAR(30)    NOT NULL,  -- MISSED_PAYMENT / DEFAULT / CURE / RESTRUCTURE
    dpd_at_event                  INT             NOT NULL DEFAULT 0,
    amount_impacted                 NUMERIC(18,2)   NULL,
    batch_id                          BIGINT          NOT NULL
);

-- Historique des notations de crédit (série temporelle pour survie/PD)
CREATE TABLE curated.fact_credit_rating_history (
    rating_key       BIGINT IDENTITY(1,1) PRIMARY KEY,
    date_key            INT             NOT NULL REFERENCES curated.dim_date(date_key),
    customer_key          BIGINT          NOT NULL REFERENCES curated.dim_customer(customer_key),
    bureau_score             INT             NOT NULL,
    internal_rating             NVARCHAR(20)    NULL,
    batch_id                      BIGINT          NOT NULL
);
GO
