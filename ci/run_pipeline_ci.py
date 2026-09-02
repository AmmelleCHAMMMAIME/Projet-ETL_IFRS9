"""
Script d'intégration continue : déploie le schéma complet sur une instance
SQL Server éphémère, génère et charge un jeu de données synthétique, exécute
le pipeline ETL de bout en bout, puis vérifie que l'exécution s'est terminée
avec succès (exit code non nul sinon — utilisé par GitHub Actions pour le
badge de statut du dépôt).

Ce script exécute réellement le code SQL du dépôt à chaque push : le badge
"build passing" atteste que le pipeline fonctionne, pas seulement qu'il existe.
"""

import re
import subprocess
import sys
from datetime import date
from pathlib import Path

import pymssql

REPO_ROOT = Path(__file__).resolve().parents[1]
SQL_DIR = REPO_ROOT / "sql"
DATA_DIR = REPO_ROOT / "data"

# Ordre de déploiement identique à sql/deploy_all.sql
DEPLOY_ORDER = [
    "01_staging_ddl.sql",
    "02_data_quality_and_orchestration_ddl.sql",
    "03_cleansed_ddl.sql",
    "04_curated_star_schema_ddl.sql",
    "05_feature_mart_ddl.sql",
    "00_populate_dim_date.sql",
    "00b_seed_reference_dimensions.sql",
    "06_proc_cleanse_and_validate.sql",
    "07_proc_scd2_dim_customer.sql",
    "08_proc_load_fact_tables.sql",
    "09_proc_compute_risk_features.sql",
    "10_recursive_cte_group_exposure.sql",
    "11_proc_data_drift_detection.sql",
    "12_proc_orchestration.sql",
]

GO_SPLIT = re.compile(r"(?im)^\s*GO\s*$")


def run_sql_file(conn, path: Path):
    content = path.read_text(encoding="utf-8")
    batches = [b.strip() for b in GO_SPLIT.split(content) if b.strip()]
    cursor = conn.cursor()
    for batch in batches:
        cursor.execute(batch)
    conn.commit()


def deploy_schema(conn):
    print("== Déploiement du schéma ==")
    for filename in DEPLOY_ORDER:
        path = SQL_DIR / filename
        print(f"  -> {filename}")
        run_sql_file(conn, path)
    print("Schéma déployé avec succès.\n")


def generate_and_load_data(server, port, user, password, database):
    print("== Génération des données synthétiques ==")
    out_dir = DATA_DIR / "ci_output"
    subprocess.run(
        [sys.executable, str(DATA_DIR / "generate_synthetic_data.py"),
         "--n-customers", "300", "--n-months", "12", "--seed", "42",
         "--out-dir", str(out_dir)],
        check=True,
    )
    print("\n== Chargement en staging ==")
    subprocess.run(
        [sys.executable, str(DATA_DIR / "load_staging_via_python.py"),
         "--server", server, "--port", str(port), "--user", user,
         "--password", password, "--database", database, "--csv-dir", str(out_dir)],
        check=True,
    )
    print()


def run_pipeline_and_verify(conn, as_of_date_key: int):
    print("== Exécution du pipeline ETL ==")
    cursor = conn.cursor()
    cursor.execute(
        "EXEC etl.usp_run_full_etl @pipeline_name = %s, @as_of_date_key = %s",
        ("CI_TEST_RUN", as_of_date_key),
    )
    conn.commit()

    cursor.execute(
        "SELECT TOP 1 batch_id, status, rows_ingested, rows_quarantined, error_message "
        "FROM etl.etl_run_log WHERE pipeline_name = 'CI_TEST_RUN' ORDER BY batch_id DESC"
    )
    row = cursor.fetchone()
    if row is None:
        print("ÉCHEC : aucune entrée trouvée dans etl.etl_run_log.")
        sys.exit(1)

    batch_id, status, rows_ingested, rows_quarantined, error_message = row
    print(f"\nbatch_id={batch_id}  status={status}  "
          f"rows_ingested={rows_ingested}  rows_quarantined={rows_quarantined}")

    if status != "SUCCESS":
        print(f"ÉCHEC du pipeline : {error_message}")
        sys.exit(1)

    if not rows_ingested:
        print("ÉCHEC : le pipeline a terminé sans erreur mais n'a produit aucune ligne.")
        sys.exit(1)

    print("\nPipeline exécuté avec succès de bout en bout.")


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", default="localhost")
    parser.add_argument("--port", type=int, default=1433)
    parser.add_argument("--user", default="sa")
    parser.add_argument("--password", required=True)
    parser.add_argument("--database", default="ETL_BANCAIRE_IFRS9")
    parser.add_argument("--as-of-date-key", type=int, default=int(date.today().strftime("%Y%m%d")))
    args = parser.parse_args()

    # Connexion à 'master' pour créer la base si besoin
    admin_conn = pymssql.connect(
        server=args.server, port=str(args.port), user=args.user,
        password=args.password, database="master", autocommit=True,
    )
    admin_conn.cursor().execute(
        f"IF DB_ID('{args.database}') IS NULL CREATE DATABASE [{args.database}];"
    )
    admin_conn.close()

    conn = pymssql.connect(
        server=args.server, port=str(args.port), user=args.user,
        password=args.password, database=args.database, autocommit=False,
    )

    deploy_schema(conn)
    conn.close()  # rouvrir après le script Python de chargement, connexion indépendante

    generate_and_load_data(args.server, args.port, args.user, args.password, args.database)

    conn = pymssql.connect(
        server=args.server, port=str(args.port), user=args.user,
        password=args.password, database=args.database, autocommit=False,
    )
    run_pipeline_and_verify(conn, args.as_of_date_key)
    conn.close()


if __name__ == "__main__":
    main()
