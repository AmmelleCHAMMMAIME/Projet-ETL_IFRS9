"""
Générateur de données synthétiques pour le pipeline ETL bancaire IFRS 9.

Produit des fichiers CSV alignés sur le schéma de staging.*, permettant de
tester le pipeline de bout en bout sans données réelles. Aucune donnée
personnelle réelle n'est utilisée : tout est généré via Faker (seed fixe
pour la reproductibilité, exigence clé pour un usage de recherche).

Usage :
    python generate_synthetic_data.py --n-customers 2000 --n-months 24 --seed 42

Sortie : ./output/stg_customers.csv, stg_accounts.csv, stg_transactions.csv,
         stg_credit_bureau.csv, stg_macro_indicators.csv
"""

import argparse
import csv
import random
import zlib
from datetime import date, timedelta
from pathlib import Path

from faker import Faker

SEGMENTS = ["Retail", "SME", "Corporate"]
PRODUCTS = ["MTG-STD", "CONS-PERS", "CONS-AUTO", "SME-WC", "SME-EQUIP", "CORP-LOC"]
BRANCHES = ["BR-TUN-01", "BR-TUN-02", "BR-TUN-03", "BR-TUN-04"]
CURRENCIES = ["TND", "EUR", "USD"]


def month_range(n_months: int, end_date: date):
    months = []
    y, m = end_date.year, end_date.month
    for _ in range(n_months):
        months.append(date(y, m, 1))
        m -= 1
        if m == 0:
            m = 12
            y -= 1
    return sorted(months)


def generate(n_customers: int, n_months: int, seed: int, out_dir: Path):
    fake = Faker("fr_FR")
    Faker.seed(seed)
    random.seed(seed)

    out_dir.mkdir(parents=True, exist_ok=True)
    today = date.today()
    months = month_range(n_months, today)

    customers, accounts, transactions, bureau_rows, macro_rows = [], [], [], [], []

    # ---- Clients ----
    for i in range(1, n_customers + 1):
        cust_id = f"CUST-{i:06d}"
        onboarding = fake.date_between(start_date="-8y", end_date="-6m")
        base_score = random.randint(350, 900)
        customers.append({
            "customer_source_id": cust_id,
            "full_name": fake.name(),
            "birth_date": fake.date_of_birth(minimum_age=20, maximum_age=75).isoformat(),
            "national_id": fake.unique.bothify(text="??########"),
            "segment": random.choices(SEGMENTS, weights=[0.7, 0.25, 0.05])[0],
            "country_code": "TN",
            "onboarding_date": onboarding.isoformat(),
        })

        # ---- 1 à 3 comptes par client ----
        n_accounts = random.choices([1, 2, 3], weights=[0.6, 0.3, 0.1])[0]
        for a in range(n_accounts):
            acc_id = f"ACC-{i:06d}-{a+1}"
            product = random.choice(PRODUCTS)
            credit_limit = round(random.uniform(2000, 250000), 2)
            accounts.append({
                "account_source_id": acc_id,
                "customer_source_id": cust_id,
                "product_code": product,
                "branch_code": random.choice(BRANCHES),
                "opening_date": fake.date_between(start_date=onboarding, end_date="-1m").isoformat(),
                "credit_limit": credit_limit,
                "interest_rate": round(random.uniform(0.03, 0.18), 4),
                "currency": random.choices(CURRENCIES, weights=[0.85, 0.1, 0.05])[0],
                "parent_group_id": "",  # laissé vide : hiérarchie groupe optionnelle
            })

            # ---- Historique de transactions mensuel avec dérive de DPD réaliste ----
            dpd = 0
            for month_idx, m in enumerate(months):
                # Probabilité de retard croissante pour ~8% des comptes ("mauvais" profils)
                is_risky = (zlib.crc32(acc_id.encode()) % 100) < 8
                if is_risky and random.random() < 0.35:
                    dpd = min(dpd + random.randint(5, 25), 180)
                else:
                    dpd = max(dpd - random.randint(0, 15), 0)

                txn_type = random.choices(
                    ["REPAYMENT", "DRAWDOWN", "FEE", "INTEREST"],
                    weights=[0.5, 0.3, 0.1, 0.1],
                )[0]
                amount = round(random.uniform(50, credit_limit * 0.15), 2)

                transactions.append({
                    "transaction_id": f"TXN-{acc_id}-{month_idx:03d}",
                    "account_source_id": acc_id,
                    "transaction_date": m.isoformat(),
                    "amount": amount,
                    "transaction_type": txn_type,
                    "dpd_snapshot": dpd,
                })

        # ---- Historique bureau de crédit (trimestriel) ----
        score = base_score
        for month_idx, m in enumerate(months):
            if month_idx % 3 != 0:
                continue
            score = max(300, min(900, score + random.randint(-20, 15)))
            bureau_rows.append({
                "customer_source_id": cust_id,
                "bureau_score": score,
                "external_default_flag": 1 if score < 400 else 0,
                "inquiry_count_12m": random.randint(0, 6),
                "report_date": m.isoformat(),
            })

    # ---- Indicateurs macroéconomiques (mensuel, scénario BASELINE) ----
    for m in months:
        macro_rows.append({
            "period_date": m.isoformat(),
            "country_code": "TN",
            "gdp_growth": round(random.uniform(-1.0, 4.0), 4),
            "unemployment_rate": round(random.uniform(13.0, 18.0), 3),
            "inflation_rate": round(random.uniform(3.0, 10.0), 3),
            "policy_rate": round(random.uniform(6.0, 9.0), 3),
            "scenario_tag": "BASELINE",
        })

    _write_csv(out_dir / "stg_customers.csv", customers)
    _write_csv(out_dir / "stg_accounts.csv", accounts)
    _write_csv(out_dir / "stg_transactions.csv", transactions)
    _write_csv(out_dir / "stg_credit_bureau.csv", bureau_rows)
    _write_csv(out_dir / "stg_macro_indicators.csv", macro_rows)

    print(f"Généré : {len(customers)} clients, {len(accounts)} comptes, "
          f"{len(transactions)} transactions, {len(bureau_rows)} relevés bureau, "
          f"{len(macro_rows)} points macro -> {out_dir}/")


def _write_csv(path: Path, rows: list[dict]):
    if not rows:
        return
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--n-customers", type=int, default=2000)
    parser.add_argument("--n-months", type=int, default=24)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--out-dir", type=str, default="output")
    args = parser.parse_args()

    generate(args.n_customers, args.n_months, args.seed, Path(__file__).parent / args.out_dir)
