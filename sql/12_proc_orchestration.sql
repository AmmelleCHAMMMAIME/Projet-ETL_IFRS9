/* ============================================================================
   ORCHESTRATION — Procédure maîtresse exécutant le pipeline complet
   staging -> cleansed -> curated (SCD2) -> feature mart -> drift monitoring
   Gestion d'erreurs avec TRY/CATCH, rollback partiel et journalisation.
   ============================================================================ */

CREATE OR ALTER PROCEDURE etl.usp_run_full_etl
    @pipeline_name NVARCHAR(100) = 'ECL_MONTHLY_PIPELINE',
    @as_of_date_key INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @batch_id BIGINT;
    DECLARE @error_message NVARCHAR(MAX);

    INSERT INTO etl.etl_run_log (pipeline_name, status)
    VALUES (@pipeline_name, 'RUNNING');
    SET @batch_id = SCOPE_IDENTITY();

    BEGIN TRY
        BEGIN TRANSACTION;

        -- 1) Nettoyage et validation qualité (staging -> cleansed)
        --    Ordre important : customers avant accounts (FK), accounts avant transactions (FK)
        EXEC etl.usp_cleanse_customers @batch_id = @batch_id;
        EXEC etl.usp_cleanse_accounts @batch_id = @batch_id;
        EXEC etl.usp_cleanse_transactions @batch_id = @batch_id;
        EXEC etl.usp_cleanse_credit_bureau @batch_id = @batch_id;

        -- 2) Historisation SCD Type 2 (cleansed -> curated) puis chargement des faits
        EXEC curated.usp_merge_dim_customer_scd2 @batch_id = @batch_id;
        EXEC curated.usp_load_fact_exposure @batch_id = @batch_id, @as_of_date_key = @as_of_date_key;
        EXEC curated.usp_load_fact_credit_event @batch_id = @batch_id;
        EXEC curated.usp_load_fact_credit_rating_history @batch_id = @batch_id;

        -- 3) Feature engineering (fonctions fenêtrées)
        EXEC feature_mart.usp_compute_customer_risk_features
             @batch_id = @batch_id, @as_of_date_key = @as_of_date_key;

        COMMIT TRANSACTION;

        UPDATE etl.etl_run_log
        SET ended_at = SYSUTCDATETIME(),
            status = 'SUCCESS',
            rows_ingested = (SELECT COUNT(*) FROM feature_mart.customer_risk_features WHERE batch_id = @batch_id),
            rows_quarantined = (SELECT COUNT(*) FROM dq.dq_quarantine WHERE batch_id = @batch_id)
        WHERE batch_id = @batch_id;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        SET @error_message = ERROR_MESSAGE();

        UPDATE etl.etl_run_log
        SET ended_at = SYSUTCDATETIME(), status = 'FAILED', error_message = @error_message
        WHERE batch_id = @batch_id;

        UPDATE etl.etl_step_log
        SET status = 'FAILED', ended_at = SYSUTCDATETIME()
        WHERE batch_id = @batch_id AND status = 'RUNNING';

        THROW;
    END CATCH
END;
GO

/* ------------------------------------------------------------------------
   Exemple d'exécution mensuelle (à orchestrer via Azure Data Factory,
   SQL Agent Job, ou Databricks Workflow selon l'environnement cible)
   ------------------------------------------------------------------------
   EXEC etl.usp_run_full_etl @pipeline_name = 'ECL_MONTHLY_PIPELINE',
                              @as_of_date_key = 20260731;

   -- Suivi de l'exécution :
   SELECT * FROM etl.etl_run_log ORDER BY batch_id DESC;
   SELECT * FROM etl.etl_step_log WHERE batch_id = (SELECT MAX(batch_id) FROM etl.etl_run_log);
   SELECT * FROM dq.dq_quarantine WHERE batch_id = (SELECT MAX(batch_id) FROM etl.etl_run_log);
------------------------------------------------------------------------- */
