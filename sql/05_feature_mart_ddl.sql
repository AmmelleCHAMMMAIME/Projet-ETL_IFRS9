/* ============================================================================
   FEATURE MART — Tables dénormalisées prêtes pour le moteur ECL / ML
   Alimente directement ton moteur IFRS9 (PD/LGD/EAD) déjà développé en Python
   ============================================================================ */

CREATE SCHEMA feature_mart;
GO

-- Features de risque par client x mois : agrégations glissantes, ratios
CREATE TABLE feature_mart.customer_risk_features (
    feature_key            BIGINT IDENTITY(1,1) PRIMARY KEY,
    date_key                  INT             NOT NULL,
    customer_key                BIGINT          NOT NULL,
    utilization_ratio              NUMERIC(6,4)    NULL,   -- solde / limite
    dpd_current                       INT             NULL,
    dpd_max_last_6m                      INT             NULL,
    dpd_trend_3m                            NUMERIC(6,2)    NULL,   -- pente calculée via fenêtre
    avg_balance_3m                            NUMERIC(18,2)   NULL,
    avg_balance_12m                              NUMERIC(18,2)   NULL,
    payment_volatility_6m                          NUMERIC(10,4)   NULL,  -- écart-type des paiements
    n_missed_payments_12m                            INT             NULL,
    bureau_score_current                                INT             NULL,
    bureau_score_delta_6m                                  INT             NULL,
    months_since_onboarding                                  INT             NULL,
    is_default_flag                                            BIT             NOT NULL DEFAULT 0,
    computed_at                                                  DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    batch_id                                                       BIGINT          NOT NULL
);
CREATE INDEX ix_feat_customer_date ON feature_mart.customer_risk_features(customer_key, date_key);

-- Inputs consolidés PD/LGD/EAD par segment x scénario macro, prêts pour le moteur ECL
CREATE TABLE feature_mart.portfolio_ecl_inputs (
    input_key             BIGINT IDENTITY(1,1) PRIMARY KEY,
    date_key                  INT             NOT NULL,
    segment                      NVARCHAR(50)    NOT NULL,
    scenario_key                    INT             NOT NULL,
    total_exposure                    NUMERIC(20,2)   NOT NULL,
    avg_pd_12m                          NUMERIC(8,6)    NULL,   -- alimenté par le modèle PD Python
    avg_lgd                                NUMERIC(8,6)    NULL,
    weighted_ead                              NUMERIC(20,2)   NULL,
    stage_1_exposure                            NUMERIC(20,2)   NULL,
    stage_2_exposure                              NUMERIC(20,2)   NULL,
    stage_3_exposure                                NUMERIC(20,2)   NULL,
    computed_ecl                                      NUMERIC(20,2)   NULL,
    batch_id                                            BIGINT          NOT NULL,
    computed_at                                           DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME()
);
GO
