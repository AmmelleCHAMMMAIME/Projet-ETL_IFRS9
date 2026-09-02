/* ============================================================================
   SCRIPT MAÎTRE DE DÉPLOIEMENT
   Exécute l'ensemble des scripts DDL et procédures dans l'ordre requis.
   Usage : sqlcmd -S <server> -d <database> -i sql/deploy_all.sql
   (ou exécution manuelle fichier par fichier dans SSMS / Azure Data Studio)
   ============================================================================ */

:r 01_staging_ddl.sql
:r 02_data_quality_and_orchestration_ddl.sql
:r 03_cleansed_ddl.sql
:r 04_curated_star_schema_ddl.sql
:r 05_feature_mart_ddl.sql
:r 00_populate_dim_date.sql
:r 00b_seed_reference_dimensions.sql
:r 06_proc_cleanse_and_validate.sql
:r 07_proc_scd2_dim_customer.sql
:r 08_proc_load_fact_tables.sql
:r 09_proc_compute_risk_features.sql
:r 10_recursive_cte_group_exposure.sql
:r 11_proc_data_drift_detection.sql
:r 12_proc_orchestration.sql

PRINT 'Déploiement terminé. Charger les données de test (voir /data) puis exécuter :';
PRINT '  EXEC etl.usp_run_full_etl @pipeline_name = ''ECL_MONTHLY_PIPELINE'', @as_of_date_key = 20260731;';
