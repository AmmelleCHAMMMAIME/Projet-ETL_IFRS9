/* ============================================================================
   ÉTAPE 3 : FEATURE ENGINEERING — fonctions fenêtrées (window functions)
   Calcule les indicateurs de risque glissants alimentant le moteur PD/LGD/EAD
   ============================================================================ */

CREATE OR ALTER PROCEDURE feature_mart.usp_compute_customer_risk_features
    @batch_id BIGINT,
    @as_of_date_key INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @step_id BIGINT;
    INSERT INTO etl.etl_step_log (batch_id, step_name) VALUES (@batch_id, 'compute_risk_features');
    SET @step_id = SCOPE_IDENTITY();

    ;WITH exposure_hist AS (
        -- Historique d'exposition des 12 derniers mois par client
        SELECT
            fe.customer_key, fe.date_key, fe.outstanding_balance, fe.credit_limit, fe.dpd_current,
            d.full_date
        FROM curated.fact_exposure fe
        INNER JOIN curated.dim_date d ON d.date_key = fe.date_key
        WHERE fe.date_key <= @as_of_date_key
          AND d.full_date >= DATEADD(MONTH, -12, (SELECT full_date FROM curated.dim_date WHERE date_key = @as_of_date_key))
    ),
    windowed AS (
        SELECT
            customer_key,
            date_key,
            outstanding_balance,
            credit_limit,
            dpd_current,
            -- Ratio d'utilisation courant
            CASE WHEN credit_limit > 0 THEN outstanding_balance / credit_limit ELSE NULL END AS utilization_ratio,
            -- Moyenne mobile 3 mois et 12 mois (fenêtre glissante bornée sur les lignes précédentes)
            AVG(outstanding_balance) OVER (
                PARTITION BY customer_key ORDER BY date_key
                ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
            ) AS avg_balance_3m,
            AVG(outstanding_balance) OVER (
                PARTITION BY customer_key ORDER BY date_key
                ROWS BETWEEN 11 PRECEDING AND CURRENT ROW
            ) AS avg_balance_12m,
            -- DPD max sur 6 mois glissants
            MAX(dpd_current) OVER (
                PARTITION BY customer_key ORDER BY date_key
                ROWS BETWEEN 5 PRECEDING AND CURRENT ROW
            ) AS dpd_max_last_6m,
            -- Tendance DPD 3 mois : différence entre valeur courante et valeur 3 mois avant (LAG)
            dpd_current - LAG(dpd_current, 3) OVER (PARTITION BY customer_key ORDER BY date_key) AS dpd_trend_3m,
            STDEV(outstanding_balance) OVER (
                PARTITION BY customer_key ORDER BY date_key
                ROWS BETWEEN 5 PRECEDING AND CURRENT ROW
            ) AS payment_volatility_6m,
            ROW_NUMBER() OVER (PARTITION BY customer_key ORDER BY date_key DESC) AS rn
        FROM exposure_hist
    ),
    bureau_latest AS (
        -- Score bureau courant et delta 6 mois (comparaison LAG sur historique de notation)
        SELECT
            customer_key,
            bureau_score AS bureau_score_current,
            bureau_score - LAG(bureau_score, 6) OVER (PARTITION BY customer_key ORDER BY date_key) AS bureau_score_delta_6m,
            ROW_NUMBER() OVER (PARTITION BY customer_key ORDER BY date_key DESC) AS rn
        FROM curated.fact_credit_rating_history
        WHERE date_key <= @as_of_date_key
    ),
    missed_payments AS (
        SELECT customer_key, COUNT(*) AS n_missed_payments_12m
        FROM curated.fact_credit_event fe
        INNER JOIN curated.dim_date d ON d.date_key = fe.date_key
        WHERE fe.event_type = 'MISSED_PAYMENT'
          AND d.full_date >= DATEADD(MONTH, -12, (SELECT full_date FROM curated.dim_date WHERE date_key = @as_of_date_key))
        GROUP BY customer_key
    )
    INSERT INTO feature_mart.customer_risk_features
        (date_key, customer_key, utilization_ratio, dpd_current, dpd_max_last_6m, dpd_trend_3m,
         avg_balance_3m, avg_balance_12m, payment_volatility_6m, n_missed_payments_12m,
         bureau_score_current, bureau_score_delta_6m, months_since_onboarding, batch_id)
    SELECT
        @as_of_date_key,
        w.customer_key,
        w.utilization_ratio,
        w.dpd_current,
        w.dpd_max_last_6m,
        w.dpd_trend_3m,
        w.avg_balance_3m,
        w.avg_balance_12m,
        w.payment_volatility_6m,
        ISNULL(mp.n_missed_payments_12m, 0),
        bl.bureau_score_current,
        bl.bureau_score_delta_6m,
        DATEDIFF(MONTH, dc.effective_date, GETUTCDATE()),
        @batch_id
    FROM windowed w
    LEFT JOIN bureau_latest bl ON bl.customer_key = w.customer_key AND bl.rn = 1
    LEFT JOIN missed_payments mp ON mp.customer_key = w.customer_key
    LEFT JOIN curated.dim_customer dc ON dc.customer_key = w.customer_key AND dc.is_current = 1
    WHERE w.rn = 1;   -- une seule ligne (la plus récente) par client pour cette date de référence

    UPDATE etl.etl_step_log
    SET ended_at = SYSUTCDATETIME(), status = 'SUCCESS', row_count = @@ROWCOUNT
    WHERE step_log_id = @step_id;
END;
GO
