/* ============================================================================
   CHARGEMENT STAGING À PARTIR DES CSV GÉNÉRÉS (data/generate_synthetic_data.py)
   Adapter @csv_path au répertoire réel (chemin accessible par le moteur SQL
   Server / Azure SQL — pour Azure SQL, utiliser OPENROWSET avec un external
   data source pointant vers Blob Storage plutôt que BULK INSERT local).
   ============================================================================ */

DECLARE @csv_path NVARCHAR(500) = 'C:\data\etl_bancaire\output\';  -- à adapter
DECLARE @new_batch_id BIGINT;

INSERT INTO etl.etl_run_log (pipeline_name, status) VALUES ('SYNTHETIC_DATA_LOAD', 'RUNNING');
SET @new_batch_id = SCOPE_IDENTITY();

DECLARE @sql NVARCHAR(MAX);

-- stg_customers
SET @sql = N'
BULK INSERT ##tmp_customers
FROM ''' + @csv_path + N'stg_customers.csv''
WITH (FORMAT = ''CSV'', FIRSTROW = 2, FIELDTERMINATOR = '','', ROWTERMINATOR = ''0x0a'', CODEPAGE = ''65001'');';

CREATE TABLE ##tmp_customers (
    customer_source_id NVARCHAR(50), full_name NVARCHAR(200), birth_date NVARCHAR(20),
    national_id NVARCHAR(50), segment NVARCHAR(50), country_code NVARCHAR(10), onboarding_date NVARCHAR(20)
);
EXEC sp_executesql @sql;

INSERT INTO staging.stg_customers
    (customer_source_id, full_name, birth_date, national_id, segment, country_code, onboarding_date, batch_id)
SELECT customer_source_id, full_name, birth_date, national_id, segment, country_code, onboarding_date, @new_batch_id
FROM ##tmp_customers;
DROP TABLE ##tmp_customers;

-- stg_accounts
CREATE TABLE ##tmp_accounts (
    account_source_id NVARCHAR(50), customer_source_id NVARCHAR(50), product_code NVARCHAR(30),
    branch_code NVARCHAR(20), opening_date NVARCHAR(20), credit_limit NVARCHAR(30),
    interest_rate NVARCHAR(20), currency NVARCHAR(10), parent_group_id NVARCHAR(50)
);
SET @sql = N'
BULK INSERT ##tmp_accounts
FROM ''' + @csv_path + N'stg_accounts.csv''
WITH (FORMAT = ''CSV'', FIRSTROW = 2, FIELDTERMINATOR = '','', ROWTERMINATOR = ''0x0a'', CODEPAGE = ''65001'');';
EXEC sp_executesql @sql;

INSERT INTO staging.stg_accounts
    (account_source_id, customer_source_id, product_code, branch_code, opening_date,
     credit_limit, interest_rate, currency, parent_group_id, batch_id)
SELECT account_source_id, customer_source_id, product_code, branch_code, opening_date,
       credit_limit, interest_rate, currency, NULLIF(parent_group_id, ''), @new_batch_id
FROM ##tmp_accounts;
DROP TABLE ##tmp_accounts;

-- stg_transactions
CREATE TABLE ##tmp_transactions (
    transaction_id NVARCHAR(50), account_source_id NVARCHAR(50), transaction_date NVARCHAR(20),
    amount NVARCHAR(30), transaction_type NVARCHAR(30), dpd_snapshot NVARCHAR(10)
);
SET @sql = N'
BULK INSERT ##tmp_transactions
FROM ''' + @csv_path + N'stg_transactions.csv''
WITH (FORMAT = ''CSV'', FIRSTROW = 2, FIELDTERMINATOR = '','', ROWTERMINATOR = ''0x0a'', CODEPAGE = ''65001'');';
EXEC sp_executesql @sql;

INSERT INTO staging.stg_transactions
    (transaction_id, account_source_id, transaction_date, amount, transaction_type, dpd_snapshot, batch_id)
SELECT transaction_id, account_source_id, transaction_date, amount, transaction_type, dpd_snapshot, @new_batch_id
FROM ##tmp_transactions;
DROP TABLE ##tmp_transactions;

-- stg_credit_bureau
CREATE TABLE ##tmp_bureau (
    customer_source_id NVARCHAR(50), bureau_score NVARCHAR(10), external_default_flag NVARCHAR(5),
    inquiry_count_12m NVARCHAR(10), report_date NVARCHAR(20)
);
SET @sql = N'
BULK INSERT ##tmp_bureau
FROM ''' + @csv_path + N'stg_credit_bureau.csv''
WITH (FORMAT = ''CSV'', FIRSTROW = 2, FIELDTERMINATOR = '','', ROWTERMINATOR = ''0x0a'', CODEPAGE = ''65001'');';
EXEC sp_executesql @sql;

INSERT INTO staging.stg_credit_bureau
    (customer_source_id, bureau_score, external_default_flag, inquiry_count_12m, report_date, batch_id)
SELECT customer_source_id, bureau_score, external_default_flag, inquiry_count_12m, report_date, @new_batch_id
FROM ##tmp_bureau;
DROP TABLE ##tmp_bureau;

-- stg_macro_indicators
CREATE TABLE ##tmp_macro (
    period_date NVARCHAR(20), country_code NVARCHAR(10), gdp_growth NVARCHAR(20),
    unemployment_rate NVARCHAR(20), inflation_rate NVARCHAR(20), policy_rate NVARCHAR(20), scenario_tag NVARCHAR(30)
);
SET @sql = N'
BULK INSERT ##tmp_macro
FROM ''' + @csv_path + N'stg_macro_indicators.csv''
WITH (FORMAT = ''CSV'', FIRSTROW = 2, FIELDTERMINATOR = '','', ROWTERMINATOR = ''0x0a'', CODEPAGE = ''65001'');';
EXEC sp_executesql @sql;

INSERT INTO staging.stg_macro_indicators
    (period_date, country_code, gdp_growth, unemployment_rate, inflation_rate, policy_rate, scenario_tag, batch_id)
SELECT period_date, country_code, gdp_growth, unemployment_rate, inflation_rate, policy_rate, scenario_tag, @new_batch_id
FROM ##tmp_macro;
DROP TABLE ##tmp_macro;

UPDATE etl.etl_run_log SET ended_at = SYSUTCDATETIME(), status = 'SUCCESS' WHERE batch_id = @new_batch_id;

PRINT 'Chargement staging terminé pour le batch_id ' + CAST(@new_batch_id AS NVARCHAR(20));
PRINT 'Lancer ensuite : EXEC etl.usp_run_full_etl @as_of_date_key = 20260731;';
