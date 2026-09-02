"""
Chargement des CSV générés vers les tables staging.*, via connexion réseau
(pymssql). Alternative à data/load_staging_from_csv.sql (BULK INSERT), utile
quand le moteur SQL Server n'a pas d'accès direct au système de fichiers
contenant les CSV — cas d'Azure SQL Database, d'un conteneur Docker distant,
ou d'un environnement d'intégration continue.

Usage :
    python load_staging_via_python.py \
        --server localhost --port 1433 --user sa --password '<motdepasse>' \
        --database ETL_BANCAIRE_IFRS9 --csv-dir ./output
"""

import argparse
import csv
from pathlib import Path

import pymssql

# Colonnes staging dans l'ordre attendu par chaque table (hors batch_id, ajouté au chargement)
TABLE_COLUMNS = {
    "stg_customers": ["customer_source_id", "full_name", "birth_date", "national_id",
                       "segment", "country_code", "onboarding_date"],
    "stg_accounts": ["account_source_id", "customer_source_id", "product_code", "branch_code",
                      "opening_date", "credit_limit", "interest_rate", "currency", "parent_group_id"],
    "stg_transactions": ["transaction_id", "account_source_id", "transaction_date",
                          "amount", "transaction_type", "dpd_snapshot"],
    "stg_credit_bureau": ["customer_source_id", "bureau_score", "external_default_flag",
                           "inquiry_count_12m", "report_date"],
    "stg_macro_indicators": ["period_date", "country_code", "gdp_growth", "unemployment_rate",
                              "inflation_rate", "policy_rate", "scenario_tag"],
}

CSV_FILES = {
    "stg_customers": "stg_customers.csv",
    "stg_accounts": "stg_accounts.csv",
    "stg_transactions": "stg_transactions.csv",
    "stg_credit_bureau": "stg_credit_bureau.csv",
    "stg_macro_indicators": "stg_macro_indicators.csv",
}


def load_table(conn, table: str, csv_path: Path, batch_id: int, batch_size: int = 1000):
    cols = TABLE_COLUMNS[table]
    if not csv_path.exists():
        print(f"  (ignoré) {csv_path} introuvable")
        return 0

    placeholders = ", ".join(["%s"] * (len(cols) + 1))
    col_list = ", ".join(cols + ["batch_id"])
    insert_sql = f"INSERT INTO staging.{table} ({col_list}) VALUES ({placeholders})"

    cursor = conn.cursor()
    total = 0
    batch = []
    with open(csv_path, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            values = [(row[c] if row[c] != "" else None) for c in cols]
            values.append(batch_id)
            batch.append(tuple(values))
            if len(batch) >= batch_size:
                cursor.executemany(insert_sql, batch)
                total += len(batch)
                batch = []
        if batch:
            cursor.executemany(insert_sql, batch)
            total += len(batch)
    conn.commit()
    return total


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", required=True)
    parser.add_argument("--port", type=int, default=1433)
    parser.add_argument("--user", required=True)
    parser.add_argument("--password", required=True)
    parser.add_argument("--database", required=True)
    parser.add_argument("--csv-dir", required=True)
    parser.add_argument("--pipeline-name", default="SYNTHETIC_DATA_LOAD")
    args = parser.parse_args()

    csv_dir = Path(args.csv_dir)
    conn = pymssql.connect(
        server=args.server, port=str(args.port), user=args.user,
        password=args.password, database=args.database, autocommit=False,
    )

    cursor = conn.cursor()
    cursor.execute(
        "INSERT INTO etl.etl_run_log (pipeline_name, status) OUTPUT INSERTED.batch_id VALUES (%s, 'RUNNING')",
        (args.pipeline_name,),
    )
    batch_id = cursor.fetchone()[0]
    conn.commit()

    # Ordre de chargement respectant les dépendances FK en aval (cleansed)
    for table in ["stg_customers", "stg_accounts", "stg_transactions",
                  "stg_credit_bureau", "stg_macro_indicators"]:
        n = load_table(conn, table, csv_dir / CSV_FILES[table], batch_id)
        print(f"  {table}: {n} lignes chargées (batch_id={batch_id})")

    cursor.execute(
        "UPDATE etl.etl_run_log SET ended_at = SYSUTCDATETIME(), status = 'SUCCESS' WHERE batch_id = %s",
        (batch_id,),
    )
    conn.commit()
    conn.close()

    print(f"\nChargement staging terminé — batch_id = {batch_id}")
    print(f"Lancer ensuite : EXEC etl.usp_run_full_etl @as_of_date_key = <YYYYMMDD>;")
    return batch_id


if __name__ == "__main__":
    main()
