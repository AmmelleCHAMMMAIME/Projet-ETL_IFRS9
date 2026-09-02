/* ============================================================================
   COUCHE CLEANSED — Données typées, validées, dédupliquées
   Alimentée uniquement par des lignes ayant passé les règles dq.dq_rules
   ============================================================================ */

CREATE SCHEMA cleansed;
GO

CREATE TABLE cleansed.customers (
    customer_source_id  NVARCHAR(50)    NOT NULL PRIMARY KEY,
    full_name             NVARCHAR(200)   NOT NULL,
    birth_date              DATE            NULL,
    national_id              NVARCHAR(50)    NULL,
    segment                    NVARCHAR(50)    NOT NULL,
    country_code                NVARCHAR(10)    NOT NULL,
    onboarding_date              DATE            NULL,
    batch_id                      BIGINT          NOT NULL,
    updated_at                    DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME()
);

CREATE TABLE cleansed.accounts (
    account_source_id   NVARCHAR(50)    NOT NULL PRIMARY KEY,
    customer_source_id   NVARCHAR(50)    NOT NULL REFERENCES cleansed.customers(customer_source_id),
    product_code           NVARCHAR(30)    NOT NULL,
    branch_code              NVARCHAR(20)    NOT NULL,
    opening_date               DATE            NOT NULL,
    credit_limit                  NUMERIC(18,2)   NOT NULL CHECK (credit_limit >= 0),
    interest_rate                  NUMERIC(6,4)    NULL,
    currency                        NVARCHAR(10)    NOT NULL,
    parent_group_id                  NVARCHAR(50)    NULL,   -- auto-référence logique pour hiérarchie groupe
    batch_id                          BIGINT          NOT NULL,
    updated_at                        DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME()
);

CREATE TABLE cleansed.transactions (
    transaction_id        NVARCHAR(50)    NOT NULL PRIMARY KEY,
    account_source_id      NVARCHAR(50)    NOT NULL REFERENCES cleansed.accounts(account_source_id),
    transaction_date         DATE            NOT NULL,
    amount                     NUMERIC(18,2)   NOT NULL,
    transaction_type            NVARCHAR(30)    NOT NULL,
    dpd_snapshot                  INT             NOT NULL DEFAULT 0,
    batch_id                        BIGINT          NOT NULL,
    updated_at                      DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME()
);

CREATE TABLE cleansed.credit_bureau (
    customer_source_id  NVARCHAR(50)    NOT NULL REFERENCES cleansed.customers(customer_source_id),
    report_date            DATE            NOT NULL,
    bureau_score              INT             NOT NULL CHECK (bureau_score BETWEEN 0 AND 1000),
    external_default_flag       BIT             NOT NULL DEFAULT 0,
    inquiry_count_12m             INT             NOT NULL DEFAULT 0,
    batch_id                        BIGINT          NOT NULL,
    updated_at                      DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    PRIMARY KEY (customer_source_id, report_date)
);

CREATE TABLE cleansed.macro_indicators (
    period_date        DATE            NOT NULL,
    country_code          NVARCHAR(10)    NOT NULL,
    gdp_growth               NUMERIC(8,4)    NULL,
    unemployment_rate          NUMERIC(6,3)    NULL,
    inflation_rate                NUMERIC(6,3)    NULL,
    policy_rate                    NUMERIC(6,3)    NULL,
    scenario_tag                     NVARCHAR(30)    NOT NULL DEFAULT 'BASELINE',
    batch_id                          BIGINT          NOT NULL,
    updated_at                        DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    PRIMARY KEY (period_date, country_code, scenario_tag)
);

CREATE INDEX ix_cln_transactions_account_date ON cleansed.transactions(account_source_id, transaction_date);
CREATE INDEX ix_cln_accounts_customer ON cleansed.accounts(customer_source_id);
GO
