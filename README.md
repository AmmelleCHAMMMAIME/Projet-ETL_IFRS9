# ETL Bancaire IFRS 9 — Pipeline de risque de crédit

[![Test ETL Pipeline](https://github.com/AmmelleCHAMMMAIME/Projet_ETL_IFRS9/actions/workflows/test-pipeline.yml/badge.svg)](https://github.com/AmmelleCHAMMMAIME/Projet_ETL_IFRS9/actions/workflows/test-pipeline.yml)
[![Licence MIT](https://img.shields.io/badge/licence-MIT-D98B3E.svg)](LICENSE)

**[Page vitrine du projet →](https://ammellechammmaime.github.io/Projet_ETL_IFRS9/)**

Pipeline ETL T-SQL (SQL Server / Azure SQL) pour la préparation de données de
risque de crédit sous IFRS 9, conçu comme fondation reproductible pour le
calcul de l'Expected Credit Loss (ECL) et comme socle d'un projet de recherche
doctorale en ingénierie de la donnée appliquée à la finance.

Le badge ci-dessus n'est pas décoratif : à chaque push, un workflow GitHub
Actions déploie le schéma complet sur une instance SQL Server éphémère,
génère un jeu de données synthétique, charge le pipeline et vérifie que
l'exécution se termine avec succès (voir [`.github/workflows/test-pipeline.yml`](.github/workflows/test-pipeline.yml)).

Ce projet complète mon moteur de modélisation PD/LGD/EAD (Python, ensemble ML)
en fournissant l'infrastructure de données amont : ingestion, qualité,
historisation et surveillance de dérive — la partie généralement absente des
travaux académiques en risque de crédit.

## Pourquoi ce projet

La plupart des publications en risque de crédit supposent des données propres
et stables. En pratique, la fiabilité d'un calcul ECL dépend autant de
l'architecture de données que du modèle statistique : traçabilité des
transformations, historisation des attributs clients, détection de la dérive
des distributions d'entrée. Ce dépôt traite ces sujets comme des composantes
de premier plan, pas comme des détails d'implémentation.

La note de cadrage complète (positionnement de recherche, problématique,
axes) est disponible dans [`docs/Note_de_cadrage_ETL_Bancaire_Doctorat.docx`](docs/Note_de_cadrage_ETL_Bancaire_Doctorat.docx).

## Architecture

Pipeline en quatre couches (architecture medallion), orchestré par des
procédures stockées avec journalisation complète et gestion d'erreurs :

```
staging  →  cleansed  →  curated (star schema, SCD2)  →  feature_mart
  (brut)     (typé,        (dimensions historisées,        (indicateurs de
              validé)       faits d'exposition)              risque pour ML)
```

| Couche | Rôle |
|---|---|
| **staging** | Ingestion brute multi-sources (core banking, bureau de crédit, macro), sans transformation, tracée par `batch_id` |
| **cleansed** | Typage strict, validation, dédoublonnage — alimentée uniquement par les lignes ayant passé les règles `dq.dq_rules` |
| **curated** | Star schema : dimensions en SCD Type 2 (`dim_customer`) et faits (`fact_exposure`, `fact_credit_event`, `fact_credit_rating_history`) |
| **feature_mart** | Indicateurs de risque calculés par fonctions fenêtrées (ratios d'utilisation, tendances DPD, volatilité), prêts pour le moteur PD/LGD/EAD |

Deux composantes transversales soutiennent l'auditabilité et la robustesse
scientifique du pipeline :

- **Gouvernance de la donnée** (`schema etl`, `schema dq`) : journal
  d'exécution (`etl_run_log`, `etl_step_log`), règles de qualité
  déclaratives, quarantaine documentée des rejets avec charge utile JSON.
- **Détection de dérive** (`dq.dq_drift_metrics`) : calcul du Population
  Stability Index (PSI) entre deux fenêtres temporelles sur les variables du
  feature mart.

## Structure du dépôt

```
etl-bancaire-ifrs9/
├── .github/workflows/
│   └── test-pipeline.yml                      # CI : déploie + teste le pipeline à chaque push
├── sql/
│   ├── 00_populate_dim_date.sql
│   ├── 00b_seed_reference_dimensions.sql
│   ├── 01_staging_ddl.sql
│   ├── 02_data_quality_and_orchestration_ddl.sql
│   ├── 03_cleansed_ddl.sql
│   ├── 04_curated_star_schema_ddl.sql
│   ├── 05_feature_mart_ddl.sql
│   ├── 06_proc_cleanse_and_validate.sql       # staging -> cleansed + quarantaine
│   ├── 07_proc_scd2_dim_customer.sql          # historisation SCD Type 2
│   ├── 08_proc_load_fact_tables.sql           # cleansed -> curated (faits)
│   ├── 09_proc_compute_risk_features.sql      # feature engineering (window functions)
│   ├── 10_recursive_cte_group_exposure.sql    # CTE récursive, hiérarchie groupe
│   ├── 11_proc_data_drift_detection.sql       # PSI / monitoring de dérive
│   ├── 12_proc_orchestration.sql              # procédure maîtresse (TRY/CATCH, transaction)
│   └── deploy_all.sql                         # script d'exécution ordonnée (sqlcmd)
├── data/
│   ├── generate_synthetic_data.py             # jeu de données synthétique (Faker, reproductible)
│   ├── compute_dashboard_metrics.py           # métriques — dashboard Portefeuille
│   ├── compute_quality_metrics.py             # métriques — dashboard Qualité & pipeline
│   ├── compute_drift_metrics.py               # métriques — dashboard Dérive & monitoring
│   ├── load_staging_from_csv.sql              # chargement BULK INSERT (SQL Server on-prem)
│   ├── load_staging_via_python.py             # chargement réseau (Azure SQL, Docker, CI)
│   └── requirements.txt
├── ci/
│   ├── run_pipeline_ci.py                     # déploiement + données + exécution + vérification
│   └── wait_for_sql.py                        # attente de disponibilité SQL Server
├── docs/
│   ├── index.html                             # page vitrine (GitHub Pages)
│   ├── dashboards.html                        # hub — suite de 3 dashboards
│   ├── dashboard-portfolio.html               # dashboard 1/3 — vue métier (exposition, IFRS 9)
│   ├── dashboard-quality.html                 # dashboard 2/3 — qualité des données & pipeline
│   ├── dashboard-drift.html                   # dashboard 3/3 — dérive & monitoring (PSI)
│   ├── dashboard_data.json                    # données — dashboard Portefeuille
│   ├── dashboard_quality_data.json            # données — dashboard Qualité
│   ├── dashboard_drift_data.json              # données — dashboard Dérive
│   ├── assets/dashboard-theme.css             # design system partagé des 3 dashboards
│   ├── assets/dashboard-common.js             # helpers JS partagés (couleurs, formatage)
│   └── Note_de_cadrage_ETL_Bancaire_Doctorat.docx
├── LICENSE
└── .gitignore
```

## Démarrage rapide

**1. Déployer le schéma** (SSMS, Azure Data Studio, ou `sqlcmd`) :

```sql
:r sql/deploy_all.sql
```

Ou fichier par fichier, dans l'ordre numérique du dossier `sql/`.

**2. Générer un jeu de données synthétique** (aucune donnée réelle n'est
utilisée — génération via [Faker](https://faker.readthedocs.io/), seed fixe
pour la reproductibilité) :

```bash
cd data
pip install -r requirements.txt
python generate_synthetic_data.py --n-customers 2000 --n-months 24 --seed 42
```

**3. Charger les CSV en staging** — deux options :

- **`load_staging_via_python.py`** (recommandé) : fonctionne quel que soit
  l'hébergement du moteur SQL (Docker, Azure SQL, distant), aucune contrainte
  d'accès filesystem côté serveur :
  ```bash
  python load_staging_via_python.py --server localhost --port 1433 \
      --user sa --password '<motdepasse>' --database ETL_BANCAIRE_IFRS9 \
      --csv-dir ./output
  ```
- **`load_staging_from_csv.sql`** (`BULK INSERT`) : plus rapide sur de gros
  volumes, mais exige que le moteur SQL Server ait un accès filesystem direct
  au dossier des CSV — adapter `@csv_path` en conséquence.

**4. Lancer le pipeline complet** :

```sql
EXEC etl.usp_run_full_etl
     @pipeline_name = 'ECL_MONTHLY_PIPELINE',
     @as_of_date_key = 20260731;

-- Suivi de l'exécution
SELECT * FROM etl.etl_run_log ORDER BY batch_id DESC;
SELECT * FROM etl.etl_step_log WHERE batch_id = (SELECT MAX(batch_id) FROM etl.etl_run_log);
SELECT * FROM dq.dq_quarantine WHERE batch_id = (SELECT MAX(batch_id) FROM etl.etl_run_log);
```

## Intégration continue

Le workflow [`test-pipeline.yml`](.github/workflows/test-pipeline.yml) lance
un conteneur SQL Server 2022 éphémère à chaque push sur `main`, puis exécute
[`ci/run_pipeline_ci.py`](ci/run_pipeline_ci.py) : déploiement du schéma,
génération et chargement de 300 clients synthétiques sur 12 mois, exécution
de `etl.usp_run_full_etl`, et vérification que le statut final est `SUCCESS`
avec au moins une ligne produite en `feature_mart`. Le job échoue sinon — le
badge reflète donc un test réel, pas une convention.

Pour un mot de passe SA personnalisé plutôt que la valeur par défaut du
workflow, ajouter un secret de dépôt `CI_SA_PASSWORD` dans *Settings > Secrets
and variables > Actions*.

**Dépannage.** Si GitHub Actions signale une "Invalid workflow file" /
erreur de syntaxe YAML, c'est presque toujours dû à un bloc `run: |`
multi-lignes mal indenté ou à des expressions `${{ }}` imbriquées dans des
guillemets shell. Le workflow de ce dépôt évite volontairement ce piège : la
logique d'attente de SQL Server est isolée dans `ci/wait_for_sql.py` plutôt
qu'écrite en ligne dans le YAML, et les mots de passe transitent par des
variables d'environnement (`env:`) plutôt que d'être réinterpolés à chaque
étape.

## Suite de dashboards analytiques

[`docs/dashboards.html`](docs/dashboards.html) — hub distribuant trois
tableaux de bord, chacun pensé pour un public différent :

| Dashboard | Public | Contenu |
|---|---|---|
| [`dashboard-portfolio.html`](docs/dashboard-portfolio.html) | Risk manager | Exposition totale, staging IFRS 9, distributions DPD/score bureau, exposition par produit et par région |
| [`dashboard-quality.html`](docs/dashboard-quality.html) | Data engineer | Catalogue de règles `dq.dq_rules`, taux de conformité par table, volumes ingérés, séquence d'orchestration réelle |
| [`dashboard-drift.html`](docs/dashboard-drift.html) | Data scientist / MLOps | Population Stability Index multi-variables dans le temps, distribution comparée référence vs. courant |

Les trois partagent un design system commun
([`docs/assets/dashboard-theme.css`](docs/assets/dashboard-theme.css),
[`dashboard-common.js`](docs/assets/dashboard-common.js)) et une navigation
croisée. Chaque JSON de données (`docs/dashboard*_data.json`) est calculé par
un script Python dédié qui **réplique la logique métier des procédures
T-SQL** (calcul d'exposition, staging IFRS 9, formule PSI) sur un échantillon
synthétique — pas de données bancaires réelles, pas de chiffres inventés.

Pour régénérer les trois dashboards avec un nouvel échantillon :

```bash
cd data
python generate_synthetic_data.py --n-customers 3000 --n-months 24 --seed 42 --out-dir dashboard_sample
python compute_dashboard_metrics.py
python compute_quality_metrics.py
python compute_drift_metrics.py
```

## Page vitrine (GitHub Pages)

Le dossier `docs/` contient une page de présentation du projet (architecture,
diagramme du modèle en étoile, techniques SQL démontrées). Pour l'activer :

1. *Settings > Pages*
2. *Source* : `Deploy from a branch`
3. *Branch* : `main`, dossier `/docs`
4. Enregistrer — la page est disponible sous `https://ammellechammmaime.github.io/Projet_ETL_IFRS9/`

C'est déjà activé pour ce dépôt (branche `main`, dossier `/docs`).

## Techniques SQL démontrées

- `MERGE` pour l'historisation SCD Type 2 avec détection de changement
- CTE récursive pour la hiérarchie d'exposition groupe (agrégation type Bâle)
- Fonctions fenêtrées (`LAG`, moyennes mobiles bornées, `STDEV` glissant,
  `NTILE`) pour le feature engineering et le calcul du PSI
- `TRY_CONVERT` et quarantaine systématique pour l'ingestion tolérante aux
  erreurs sans perte d'information (payload JSON conservé)
- Orchestration transactionnelle avec `TRY/CATCH`, `THROW` et journalisation
  par étape

## Prochaines étapes

- Ajouter des procédures de calcul agrégé PD/LGD/EAD à partir de
  `feature_mart.customer_risk_features`, en lien avec le moteur Python déjà
  développé.
- Étendre le monitoring de dérive à l'ensemble des variables du feature mart
  (actuellement démontré sur `utilization_ratio`).
- Ajouter des tests de qualité automatisés (ex. tSQLt) sur les procédures de
  nettoyage et d'historisation.

## Licence

MIT — voir [LICENSE](LICENSE).
