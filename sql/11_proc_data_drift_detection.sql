/* ============================================================================
   DÉTECTION DE DÉRIVE DES DONNÉES (DATA DRIFT) — Population Stability Index
   Composante de recherche : surveille la stabilité des distributions des
   variables d'entrée du modèle de risque entre deux fenêtres temporelles.
   Un PSI > 0.25 indique une dérive significative nécessitant un ré-entraînement.
   ============================================================================ */

CREATE OR ALTER PROCEDURE dq.usp_detect_feature_drift
    @batch_id BIGINT,
    @reference_period NVARCHAR(20),   -- ex : '2025-Q1'
    @current_period NVARCHAR(20),     -- ex : '2026-Q1'
    @reference_date_from DATE,
    @reference_date_to DATE,
    @current_date_from DATE,
    @current_date_to DATE
AS
BEGIN
    SET NOCOUNT ON;

    -- Comparaison simplifiée basée sur des bandes (bins) de utilization_ratio,
    -- à généraliser à toute variable numérique du feature mart.
    -- Note : une fonction fenêtrée (NTILE) ne peut apparaître qu'en SELECT ou
    -- ORDER BY — le bucket est donc calculé dans une sous-requête puis agrégé
    -- séparément (GROUP BY sur une fonction fenêtrée est interdit en T-SQL).
    ;WITH ref_binned AS (
        SELECT
            f.utilization_ratio,
            NTILE(10) OVER (ORDER BY f.utilization_ratio) AS bucket
        FROM feature_mart.customer_risk_features f
        INNER JOIN curated.dim_date d ON d.date_key = f.date_key
        WHERE d.full_date BETWEEN @reference_date_from AND @reference_date_to
          AND f.utilization_ratio IS NOT NULL
    ),
    ref_dist AS (
        SELECT bucket, COUNT(*) AS ref_count
        FROM ref_binned
        GROUP BY bucket
    ),
    cur_binned AS (
        SELECT
            f.utilization_ratio,
            NTILE(10) OVER (ORDER BY f.utilization_ratio) AS bucket
        FROM feature_mart.customer_risk_features f
        INNER JOIN curated.dim_date d ON d.date_key = f.date_key
        WHERE d.full_date BETWEEN @current_date_from AND @current_date_to
          AND f.utilization_ratio IS NOT NULL
    ),
    cur_dist AS (
        SELECT bucket, COUNT(*) AS cur_count
        FROM cur_binned
        GROUP BY bucket
    ),
    ref_total AS (SELECT SUM(ref_count) AS t FROM ref_dist),
    cur_total AS (SELECT SUM(cur_count) AS t FROM cur_dist),
    psi_calc AS (
        SELECT
            r.bucket,
            CAST(r.ref_count AS FLOAT) / NULLIF(rt.t, 0) AS ref_pct,
            CAST(c.cur_count AS FLOAT) / NULLIF(ct.t, 0) AS cur_pct
        FROM ref_dist r
        INNER JOIN cur_dist c ON c.bucket = r.bucket
        CROSS JOIN ref_total rt
        CROSS JOIN cur_total ct
    )
    INSERT INTO dq.dq_drift_metrics
        (batch_id, feature_name, reference_period, current_period,
         reference_mean, current_mean, population_stability_index, drift_flag)
    SELECT
        @batch_id,
        'utilization_ratio',
        @reference_period,
        @current_period,
        (SELECT AVG(utilization_ratio) FROM feature_mart.customer_risk_features f
            INNER JOIN curated.dim_date d ON d.date_key = f.date_key
            WHERE d.full_date BETWEEN @reference_date_from AND @reference_date_to),
        (SELECT AVG(utilization_ratio) FROM feature_mart.customer_risk_features f
            INNER JOIN curated.dim_date d ON d.date_key = f.date_key
            WHERE d.full_date BETWEEN @current_date_from AND @current_date_to),
        -- PSI = somme( (cur% - ref%) * ln(cur% / ref%) ) sur tous les bins
        SUM((ISNULL(cur_pct,0.0001) - ISNULL(ref_pct,0.0001))
            * LOG(NULLIF(ISNULL(cur_pct,0.0001),0) / NULLIF(ISNULL(ref_pct,0.0001),0))),
        CASE WHEN SUM((ISNULL(cur_pct,0.0001) - ISNULL(ref_pct,0.0001))
                 * LOG(NULLIF(ISNULL(cur_pct,0.0001),0) / NULLIF(ISNULL(ref_pct,0.0001),0))) > 0.25
             THEN 1 ELSE 0 END
    FROM psi_calc;
END;
GO
