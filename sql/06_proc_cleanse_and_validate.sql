/* ============================================================================
   ÉTAPE 1 : STAGING -> CLEANSED, avec application des règles DQ et quarantaine
   ============================================================================ */

CREATE OR ALTER PROCEDURE etl.usp_cleanse_customers
    @batch_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @step_id BIGINT;

    INSERT INTO etl.etl_step_log (batch_id, step_name) VALUES (@batch_id, 'cleanse_customers');
    SET @step_id = SCOPE_IDENTITY();

    -- 1) Quarantaine des lignes invalides (clé nulle, doublon, type non convertible)
    INSERT INTO dq.dq_quarantine (batch_id, source_table, source_row_id, failure_reason, raw_payload)
    SELECT
        @batch_id,
        'stg_customers',
        s.row_id,
        CASE
            WHEN s.customer_source_id IS NULL THEN 'customer_source_id NULL'
            WHEN TRY_CONVERT(DATE, s.birth_date) IS NULL AND s.birth_date IS NOT NULL THEN 'birth_date non convertible'
            WHEN s.segment IS NULL THEN 'segment manquant'
            ELSE 'raison inconnue'
        END,
        (SELECT s.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM staging.stg_customers s
    WHERE s.is_processed = 0
      AND (
            s.customer_source_id IS NULL
         OR s.segment IS NULL
         OR (s.birth_date IS NOT NULL AND TRY_CONVERT(DATE, s.birth_date) IS NULL)
      );

    -- 2) Upsert des lignes valides vers cleansed (dédoublonnage sur la clé naturelle,
    --    on garde la ligne la plus récente du batch en cas de doublons)
    ;WITH valid_rows AS (
        SELECT s.*,
               ROW_NUMBER() OVER (PARTITION BY s.customer_source_id ORDER BY s.load_ts DESC) AS rn
        FROM staging.stg_customers s
        WHERE s.is_processed = 0
          AND s.customer_source_id IS NOT NULL
          AND s.segment IS NOT NULL
          AND (s.birth_date IS NULL OR TRY_CONVERT(DATE, s.birth_date) IS NOT NULL)
    )
    MERGE cleansed.customers AS tgt
    USING (SELECT * FROM valid_rows WHERE rn = 1) AS src
    ON tgt.customer_source_id = src.customer_source_id
    WHEN MATCHED THEN
        UPDATE SET
            full_name = src.full_name,
            birth_date = TRY_CONVERT(DATE, src.birth_date),
            national_id = src.national_id,
            segment = src.segment,
            country_code = src.country_code,
            onboarding_date = TRY_CONVERT(DATE, src.onboarding_date),
            batch_id = @batch_id,
            updated_at = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN
        INSERT (customer_source_id, full_name, birth_date, national_id, segment,
                country_code, onboarding_date, batch_id)
        VALUES (src.customer_source_id, src.full_name, TRY_CONVERT(DATE, src.birth_date),
                src.national_id, src.segment, src.country_code,
                TRY_CONVERT(DATE, src.onboarding_date), @batch_id);

    -- 3) Marquer le staging comme traité
    UPDATE staging.stg_customers SET is_processed = 1 WHERE is_processed = 0;

    UPDATE etl.etl_step_log
    SET ended_at = SYSUTCDATETIME(), status = 'SUCCESS', row_count = @@ROWCOUNT
    WHERE step_log_id = @step_id;
END;
GO

/* ----------------------------------------------------------------------
   Comptes : dépend de cleansed.customers déjà chargée dans le même batch
   ---------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE etl.usp_cleanse_accounts
    @batch_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @step_id BIGINT;
    INSERT INTO etl.etl_step_log (batch_id, step_name) VALUES (@batch_id, 'cleanse_accounts');
    SET @step_id = SCOPE_IDENTITY();

    INSERT INTO dq.dq_quarantine (batch_id, source_table, source_row_id, failure_reason, raw_payload)
    SELECT
        @batch_id, 'stg_accounts', s.row_id,
        CASE
            WHEN s.account_source_id IS NULL THEN 'account_source_id NULL'
            WHEN NOT EXISTS (SELECT 1 FROM cleansed.customers c WHERE c.customer_source_id = s.customer_source_id)
                 THEN 'customer_source_id inconnu en cleansed.customers'
            WHEN TRY_CONVERT(NUMERIC(18,2), s.credit_limit) IS NULL THEN 'credit_limit non convertible'
            WHEN TRY_CONVERT(NUMERIC(18,2), s.credit_limit) < 0 THEN 'credit_limit négatif'
            WHEN TRY_CONVERT(DATE, s.opening_date) IS NULL THEN 'opening_date non convertible'
            ELSE 'raison inconnue'
        END,
        (SELECT s.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM staging.stg_accounts s
    WHERE s.is_processed = 0
      AND (
            s.account_source_id IS NULL
         OR NOT EXISTS (SELECT 1 FROM cleansed.customers c WHERE c.customer_source_id = s.customer_source_id)
         OR TRY_CONVERT(NUMERIC(18,2), s.credit_limit) IS NULL
         OR TRY_CONVERT(NUMERIC(18,2), s.credit_limit) < 0
         OR TRY_CONVERT(DATE, s.opening_date) IS NULL
      );

    ;WITH valid_rows AS (
        SELECT s.*, ROW_NUMBER() OVER (PARTITION BY s.account_source_id ORDER BY s.load_ts DESC) AS rn
        FROM staging.stg_accounts s
        WHERE s.is_processed = 0
          AND s.account_source_id IS NOT NULL
          AND EXISTS (SELECT 1 FROM cleansed.customers c WHERE c.customer_source_id = s.customer_source_id)
          AND TRY_CONVERT(NUMERIC(18,2), s.credit_limit) >= 0
          AND TRY_CONVERT(DATE, s.opening_date) IS NOT NULL
    )
    MERGE cleansed.accounts AS tgt
    USING (SELECT * FROM valid_rows WHERE rn = 1) AS src
    ON tgt.account_source_id = src.account_source_id
    WHEN MATCHED THEN
        UPDATE SET
            customer_source_id = src.customer_source_id,
            product_code = src.product_code,
            branch_code = src.branch_code,
            opening_date = TRY_CONVERT(DATE, src.opening_date),
            credit_limit = TRY_CONVERT(NUMERIC(18,2), src.credit_limit),
            interest_rate = TRY_CONVERT(NUMERIC(6,4), src.interest_rate),
            currency = src.currency,
            parent_group_id = src.parent_group_id,
            batch_id = @batch_id,
            updated_at = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN
        INSERT (account_source_id, customer_source_id, product_code, branch_code, opening_date,
                credit_limit, interest_rate, currency, parent_group_id, batch_id)
        VALUES (src.account_source_id, src.customer_source_id, src.product_code, src.branch_code,
                TRY_CONVERT(DATE, src.opening_date), TRY_CONVERT(NUMERIC(18,2), src.credit_limit),
                TRY_CONVERT(NUMERIC(6,4), src.interest_rate), src.currency, src.parent_group_id, @batch_id);

    UPDATE staging.stg_accounts SET is_processed = 1 WHERE is_processed = 0;

    UPDATE etl.etl_step_log
    SET ended_at = SYSUTCDATETIME(), status = 'SUCCESS', row_count = @@ROWCOUNT
    WHERE step_log_id = @step_id;
END;
GO

/* ----------------------------------------------------------------------
   Transactions : dépend de cleansed.accounts
   ---------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE etl.usp_cleanse_transactions
    @batch_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @step_id BIGINT;
    INSERT INTO etl.etl_step_log (batch_id, step_name) VALUES (@batch_id, 'cleanse_transactions');
    SET @step_id = SCOPE_IDENTITY();

    INSERT INTO dq.dq_quarantine (batch_id, source_table, source_row_id, failure_reason, raw_payload)
    SELECT
        @batch_id, 'stg_transactions', s.row_id,
        CASE
            WHEN s.transaction_id IS NULL THEN 'transaction_id NULL'
            WHEN NOT EXISTS (SELECT 1 FROM cleansed.accounts a WHERE a.account_source_id = s.account_source_id)
                 THEN 'account_source_id inconnu en cleansed.accounts'
            WHEN TRY_CONVERT(NUMERIC(18,2), s.amount) IS NULL THEN 'amount non convertible'
            WHEN TRY_CONVERT(DATE, s.transaction_date) IS NULL THEN 'transaction_date non convertible'
            ELSE 'raison inconnue'
        END,
        (SELECT s.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM staging.stg_transactions s
    WHERE s.is_processed = 0
      AND (
            s.transaction_id IS NULL
         OR NOT EXISTS (SELECT 1 FROM cleansed.accounts a WHERE a.account_source_id = s.account_source_id)
         OR TRY_CONVERT(NUMERIC(18,2), s.amount) IS NULL
         OR TRY_CONVERT(DATE, s.transaction_date) IS NULL
      );

    ;WITH valid_rows AS (
        SELECT s.*, ROW_NUMBER() OVER (PARTITION BY s.transaction_id ORDER BY s.load_ts DESC) AS rn
        FROM staging.stg_transactions s
        WHERE s.is_processed = 0
          AND s.transaction_id IS NOT NULL
          AND EXISTS (SELECT 1 FROM cleansed.accounts a WHERE a.account_source_id = s.account_source_id)
          AND TRY_CONVERT(NUMERIC(18,2), s.amount) IS NOT NULL
          AND TRY_CONVERT(DATE, s.transaction_date) IS NOT NULL
    )
    MERGE cleansed.transactions AS tgt
    USING (SELECT * FROM valid_rows WHERE rn = 1) AS src
    ON tgt.transaction_id = src.transaction_id
    WHEN MATCHED THEN
        UPDATE SET
            account_source_id = src.account_source_id,
            transaction_date = TRY_CONVERT(DATE, src.transaction_date),
            amount = TRY_CONVERT(NUMERIC(18,2), src.amount),
            transaction_type = src.transaction_type,
            dpd_snapshot = ISNULL(TRY_CONVERT(INT, src.dpd_snapshot), 0),
            batch_id = @batch_id,
            updated_at = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN
        INSERT (transaction_id, account_source_id, transaction_date, amount, transaction_type, dpd_snapshot, batch_id)
        VALUES (src.transaction_id, src.account_source_id, TRY_CONVERT(DATE, src.transaction_date),
                TRY_CONVERT(NUMERIC(18,2), src.amount), src.transaction_type,
                ISNULL(TRY_CONVERT(INT, src.dpd_snapshot), 0), @batch_id);

    UPDATE staging.stg_transactions SET is_processed = 1 WHERE is_processed = 0;

    UPDATE etl.etl_step_log
    SET ended_at = SYSUTCDATETIME(), status = 'SUCCESS', row_count = @@ROWCOUNT
    WHERE step_log_id = @step_id;
END;
GO

/* ----------------------------------------------------------------------
   Bureau de crédit : dépend de cleansed.customers
   ---------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE etl.usp_cleanse_credit_bureau
    @batch_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @step_id BIGINT;
    INSERT INTO etl.etl_step_log (batch_id, step_name) VALUES (@batch_id, 'cleanse_credit_bureau');
    SET @step_id = SCOPE_IDENTITY();

    INSERT INTO dq.dq_quarantine (batch_id, source_table, source_row_id, failure_reason, raw_payload)
    SELECT
        @batch_id, 'stg_credit_bureau', s.row_id,
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM cleansed.customers c WHERE c.customer_source_id = s.customer_source_id)
                 THEN 'customer_source_id inconnu en cleansed.customers'
            WHEN TRY_CONVERT(INT, s.bureau_score) IS NULL OR TRY_CONVERT(INT, s.bureau_score) NOT BETWEEN 0 AND 1000
                 THEN 'bureau_score hors plage [0,1000]'
            WHEN TRY_CONVERT(DATE, s.report_date) IS NULL THEN 'report_date non convertible'
            ELSE 'raison inconnue'
        END,
        (SELECT s.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM staging.stg_credit_bureau s
    WHERE s.is_processed = 0
      AND (
            NOT EXISTS (SELECT 1 FROM cleansed.customers c WHERE c.customer_source_id = s.customer_source_id)
         OR TRY_CONVERT(INT, s.bureau_score) IS NULL
         OR TRY_CONVERT(INT, s.bureau_score) NOT BETWEEN 0 AND 1000
         OR TRY_CONVERT(DATE, s.report_date) IS NULL
      );

    ;WITH valid_rows AS (
        SELECT s.*, ROW_NUMBER() OVER (PARTITION BY s.customer_source_id, s.report_date ORDER BY s.load_ts DESC) AS rn
        FROM staging.stg_credit_bureau s
        WHERE s.is_processed = 0
          AND EXISTS (SELECT 1 FROM cleansed.customers c WHERE c.customer_source_id = s.customer_source_id)
          AND TRY_CONVERT(INT, s.bureau_score) BETWEEN 0 AND 1000
          AND TRY_CONVERT(DATE, s.report_date) IS NOT NULL
    )
    MERGE cleansed.credit_bureau AS tgt
    USING (SELECT * FROM valid_rows WHERE rn = 1) AS src
    ON tgt.customer_source_id = src.customer_source_id AND tgt.report_date = TRY_CONVERT(DATE, src.report_date)
    WHEN MATCHED THEN
        UPDATE SET
            bureau_score = TRY_CONVERT(INT, src.bureau_score),
            external_default_flag = ISNULL(TRY_CONVERT(BIT, src.external_default_flag), 0),
            inquiry_count_12m = ISNULL(TRY_CONVERT(INT, src.inquiry_count_12m), 0),
            batch_id = @batch_id,
            updated_at = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN
        INSERT (customer_source_id, report_date, bureau_score, external_default_flag, inquiry_count_12m, batch_id)
        VALUES (src.customer_source_id, TRY_CONVERT(DATE, src.report_date), TRY_CONVERT(INT, src.bureau_score),
                ISNULL(TRY_CONVERT(BIT, src.external_default_flag), 0),
                ISNULL(TRY_CONVERT(INT, src.inquiry_count_12m), 0), @batch_id);

    UPDATE staging.stg_credit_bureau SET is_processed = 1 WHERE is_processed = 0;

    UPDATE etl.etl_step_log
    SET ended_at = SYSUTCDATETIME(), status = 'SUCCESS', row_count = @@ROWCOUNT
    WHERE step_log_id = @step_id;
END;
GO
