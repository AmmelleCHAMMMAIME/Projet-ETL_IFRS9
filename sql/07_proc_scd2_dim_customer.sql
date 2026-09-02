/* ============================================================================
   ÉTAPE 2 : CLEANSED -> CURATED — Historisation SCD Type 2 de dim_customer
   Toute modification d'un attribut suivi (segment, score band, pays) déclenche :
     - la clôture de la version courante (expiry_date, is_current = 0)
     - l'insertion d'une nouvelle version (version_number + 1)
   ============================================================================ */

CREATE OR ALTER PROCEDURE curated.usp_merge_dim_customer_scd2
    @batch_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @step_id BIGINT, @now DATETIME2 = SYSUTCDATETIME();

    INSERT INTO etl.etl_step_log (batch_id, step_name) VALUES (@batch_id, 'merge_dim_customer_scd2');
    SET @step_id = SCOPE_IDENTITY();

    -- Source enrichie : dernier score bureau connu -> bande de score
    ;WITH src AS (
        SELECT
            c.customer_source_id,
            c.full_name,
            c.segment,
            c.country_code,
            CASE
                WHEN cb.bureau_score IS NULL THEN NULL
                WHEN cb.bureau_score < 500 THEN '0-500'
                WHEN cb.bureau_score < 600 THEN '500-600'
                WHEN cb.bureau_score < 700 THEN '600-700'
                WHEN cb.bureau_score < 750 THEN '700-750'
                ELSE '750+'
            END AS bureau_score_band
        FROM cleansed.customers c
        OUTER APPLY (
            SELECT TOP 1 bureau_score
            FROM cleansed.credit_bureau b
            WHERE b.customer_source_id = c.customer_source_id
            ORDER BY b.report_date DESC
        ) cb
        WHERE c.batch_id = @batch_id
    ),
    -- Détection de changement : comparaison avec la version courante
    changed AS (
        SELECT src.*
        FROM src
        INNER JOIN curated.dim_customer d
            ON d.customer_source_id = src.customer_source_id
           AND d.is_current = 1
        WHERE  d.full_name          <> src.full_name
            OR d.segment              <> src.segment
            OR d.country_code           <> src.country_code
            OR ISNULL(d.bureau_score_band, '') <> ISNULL(src.bureau_score_band, '')
    ),
    new_customers AS (
        SELECT src.*
        FROM src
        LEFT JOIN curated.dim_customer d ON d.customer_source_id = src.customer_source_id
        WHERE d.customer_source_id IS NULL
    )
    -- 1) Clôturer les versions modifiées
    UPDATE d
    SET expiry_date = @now, is_current = 0
    FROM curated.dim_customer d
    INNER JOIN changed c ON c.customer_source_id = d.customer_source_id
    WHERE d.is_current = 1;

    -- 2) Insérer les nouvelles versions (clients modifiés) + nouveaux clients
    ;WITH src AS (
        SELECT
            c.customer_source_id, c.full_name, c.segment, c.country_code,
            CASE
                WHEN cb.bureau_score IS NULL THEN NULL
                WHEN cb.bureau_score < 500 THEN '0-500'
                WHEN cb.bureau_score < 600 THEN '500-600'
                WHEN cb.bureau_score < 700 THEN '600-700'
                WHEN cb.bureau_score < 750 THEN '700-750'
                ELSE '750+'
            END AS bureau_score_band
        FROM cleansed.customers c
        OUTER APPLY (
            SELECT TOP 1 bureau_score FROM cleansed.credit_bureau b
            WHERE b.customer_source_id = c.customer_source_id ORDER BY b.report_date DESC
        ) cb
        WHERE c.batch_id = @batch_id
    )
    INSERT INTO curated.dim_customer
        (customer_source_id, full_name, segment, country_code, bureau_score_band,
         effective_date, expiry_date, is_current, version_number)
    SELECT
        s.customer_source_id, s.full_name, s.segment, s.country_code, s.bureau_score_band,
        @now, '9999-12-31', 1,
        ISNULL((SELECT MAX(version_number) FROM curated.dim_customer d2
                WHERE d2.customer_source_id = s.customer_source_id), 0) + 1
    FROM src s
    WHERE NOT EXISTS (
        -- exclut les versions courantes déjà identiques (rien n'a changé)
        SELECT 1 FROM curated.dim_customer d
        WHERE d.customer_source_id = s.customer_source_id
          AND d.is_current = 1
          AND d.full_name = s.full_name
          AND d.segment = s.segment
          AND d.country_code = s.country_code
          AND ISNULL(d.bureau_score_band,'') = ISNULL(s.bureau_score_band,'')
    );

    UPDATE etl.etl_step_log
    SET ended_at = SYSUTCDATETIME(), status = 'SUCCESS', row_count = @@ROWCOUNT
    WHERE step_log_id = @step_id;
END;
GO
