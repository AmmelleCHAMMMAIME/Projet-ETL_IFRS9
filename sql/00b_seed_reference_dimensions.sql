/* ============================================================================
   DONNÉES DE RÉFÉRENCE — Dimensions statiques à amorcer avant tout run ETL
   (produits, agences, scénarios macro). Ces dimensions ne sont pas SCD2 :
   elles évoluent par ajout, rarement par modification.
   ============================================================================ */

INSERT INTO curated.dim_product (product_code, product_name, product_family, is_secured)
VALUES
 ('MTG-STD', 'Prêt immobilier standard', 'Mortgage', 1),
 ('CONS-PERS', 'Crédit personnel', 'Consumer', 0),
 ('CONS-AUTO', 'Crédit automobile', 'Consumer', 1),
 ('SME-WC', 'Fonds de roulement PME', 'SME', 0),
 ('SME-EQUIP', 'Financement équipement PME', 'SME', 1),
 ('CORP-LOC', 'Ligne de crédit corporate', 'Corporate', 0);

INSERT INTO curated.dim_branch (branch_code, branch_name, region, country_code)
VALUES
 ('BR-TUN-01', 'Agence Tunis Centre', 'Grand Tunis', 'TN'),
 ('BR-TUN-02', 'Agence Sfax', 'Sud', 'TN'),
 ('BR-TUN-03', 'Agence Sousse', 'Centre-Est', 'TN'),
 ('BR-TUN-04', 'Agence Médenine', 'Sud-Est', 'TN');

INSERT INTO curated.dim_macro_scenario (scenario_tag, scenario_weight, valid_from, valid_to)
VALUES
 ('BASELINE', 0.6000, '2018-01-01', '9999-12-31'),
 ('UPSIDE',   0.2000, '2018-01-01', '9999-12-31'),
 ('DOWNSIDE', 0.2000, '2018-01-01', '9999-12-31');
GO
