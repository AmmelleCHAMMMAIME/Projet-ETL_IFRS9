/* ============================================================================
   ÉTAPE 2bis : CLEANSED -> CURATED — Chargement des tables de faits
   Alimente fact_exposure (snapshot mensuel), fact_credit_event et
   fact_credit_rating_history à partir des données nettoyées et des dimensions
   déjà historisées (dim_customer version courante à la date de traitement).
   ============================================================================ */

CREATE OR ALTER PROCEDURE curated.usp_load_fact_exposure
    @batch_id BIGINT,
    @as_of_date_key INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @step_id BIGINT;
    INSERT INTO etl.etl_step_log (batch_id, step_name) VALUES (@batch_id, 'load_fact_exposure');
    SET @step_id = SCOPE_IDENTITY();

    -- Solde courant par compte = somme des transactions jusqu'à la date de référence
    ;WITH account_balance AS (
        SELECT
            t.account_source_id,
            SUM(CASE WHEN t.transaction_type = 'DRAWDOWN' THEN t.amount
                     WHEN t.transaction_type = 'REPAYMENT' THEN -t.amount
                     ELSE t.amount END) AS outstanding_balance,
            MAX(t.dpd_snapshot) AS dpd_current
        FROM cleansed.transactions t
        INNER JOIN curated.dim_date d ON d.full_date = t.transaction_date
        WHERE d.date_key <= @as_of_date_key
        GROUP BY t.account_source_id
    ),
    default_scenario AS (
        -- Scénario BASELINE par défaut si non explicité par la donnée macro
        SELECT TOP 1 scenario_key FROM curated.dim_macro_scenario
        WHERE scenario_tag = 'BASELINE' ORDER BY valid_from DESC
    )
    INSERT INTO curated.fact_exposure
        (date_key, customer_key, product_key, branch_key, scenario_key,
         outstanding_balance, credit_limit, dpd_current, ifrs9_stage, batch_id)
    SELECT
        @as_of_date_key,
        dc.customer_key,
        dp.product_key,
        db.branch_key,
        ds.scenario_key,
        ISNULL(ab.outstanding_balance, 0),
        a.credit_limit,
        ISNULL(ab.dpd_current, 0),
        -- Staging IFRS 9 simplifié : Stage 1 (sain) / 2 (dégradé, DPD>30) / 3 (déprécié, DPD>90)
        CASE WHEN ISNULL(ab.dpd_current, 0) > 90 THEN 3
             WHEN ISNULL(ab.dpd_current, 0) > 30 THEN 2
             ELSE 1 END,
        @batch_id
    FROM cleansed.accounts a
    INNER JOIN curated.dim_customer dc ON dc.customer_source_id = a.customer_source_id AND dc.is_current = 1
    INNER JOIN curated.dim_product dp ON dp.product_code = a.product_code
    INNER JOIN curated.dim_branch db ON db.branch_code = a.branch_code
    CROSS JOIN default_scenario ds
    LEFT JOIN account_balance ab ON ab.account_source_id = a.account_source_id;

    UPDATE etl.etl_step_log
    SET ended_at = SYSUTCDATETIME(), status = 'SUCCESS', row_count = @@ROWCOUNT
    WHERE step_log_id = @step_id;
END;
GO

CREATE OR ALTER PROCEDURE curated.usp_load_fact_credit_event
    @batch_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @step_id BIGINT;
    INSERT INTO etl.etl_step_log (batch_id, step_name) VALUES (@batch_id, 'load_fact_credit_event');
    SET @step_id = SCOPE_IDENTITY();

    INSERT INTO curated.fact_credit_event (date_key, customer_key, product_key, event_type, dpd_at_event, amount_impacted, batch_id)
    SELECT
        d.date_key,
        dc.customer_key,
        dp.product_key,
        CASE WHEN t.dpd_snapshot > 90 THEN 'DEFAULT'
             WHEN t.dpd_snapshot > 0  THEN 'MISSED_PAYMENT'
             ELSE 'REGULAR' END,
        t.dpd_snapshot,
        t.amount,
        @batch_id
    FROM cleansed.transactions t
    INNER JOIN cleansed.accounts a ON a.account_source_id = t.account_source_id
    INNER JOIN curated.dim_customer dc ON dc.customer_source_id = a.customer_source_id AND dc.is_current = 1
    INNER JOIN curated.dim_product dp ON dp.product_code = a.product_code
    INNER JOIN curated.dim_date d ON d.full_date = t.transaction_date
    WHERE t.batch_id = @batch_id AND t.dpd_snapshot > 0;

    UPDATE etl.etl_step_log
    SET ended_at = SYSUTCDATETIME(), status = 'SUCCESS', row_count = @@ROWCOUNT
    WHERE step_log_id = @step_id;
END;
GO

CREATE OR ALTER PROCEDURE curated.usp_load_fact_credit_rating_history
    @batch_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @step_id BIGINT;
    INSERT INTO etl.etl_step_log (batch_id, step_name) VALUES (@batch_id, 'load_fact_credit_rating_history');
    SET @step_id = SCOPE_IDENTITY();

    INSERT INTO curated.fact_credit_rating_history (date_key, customer_key, bureau_score, internal_rating, batch_id)
    SELECT
        d.date_key,
        dc.customer_key,
        cb.bureau_score,
        CASE WHEN cb.bureau_score >= 750 THEN 'AAA'
             WHEN cb.bureau_score >= 700 THEN 'AA'
             WHEN cb.bureau_score >= 600 THEN 'A'
             WHEN cb.bureau_score >= 500 THEN 'BBB'
             ELSE 'SPECULATIVE' END,
        @batch_id
    FROM cleansed.credit_bureau cb
    INNER JOIN curated.dim_customer dc ON dc.customer_source_id = cb.customer_source_id AND dc.is_current = 1
    INNER JOIN curated.dim_date d ON d.full_date = cb.report_date
    WHERE cb.batch_id = @batch_id;

    UPDATE etl.etl_step_log
    SET ended_at = SYSUTCDATETIME(), status = 'SUCCESS', row_count = @@ROWCOUNT
    WHERE step_log_id = @step_id;
END;
GO
