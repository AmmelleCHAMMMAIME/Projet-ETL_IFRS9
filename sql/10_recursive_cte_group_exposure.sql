/* ============================================================================
   CTE RÉCURSIVE — Hiérarchie d'exposition groupe (agrégation Bâle/IFRS9)
   Un client "parent_group_id" peut être lui-même rattaché à un groupe plus large
   (ex: filiale -> holding régionale -> holding mère). L'exposition réglementaire
   doit être agrégée à travers toute la hiérarchie.
   ============================================================================ */

CREATE OR ALTER VIEW curated.vw_group_exposure_hierarchy AS
WITH RECURSIVE_GROUP AS (
    -- Ancre : comptes racines (pas de parent, ou parent = eux-mêmes)
    SELECT
        a.account_source_id,
        a.customer_source_id,
        a.parent_group_id,
        a.account_source_id AS root_group_id,
        0 AS hierarchy_level,
        CAST(a.account_source_id AS NVARCHAR(4000)) AS hierarchy_path
    FROM cleansed.accounts a
    WHERE a.parent_group_id IS NULL

    UNION ALL

    -- Récursion : on remonte vers les enfants dont le parent existe dans le niveau courant
    SELECT
        child.account_source_id,
        child.customer_source_id,
        child.parent_group_id,
        rg.root_group_id,
        rg.hierarchy_level + 1,
        rg.hierarchy_path + ' > ' + child.account_source_id
    FROM cleansed.accounts child
    INNER JOIN RECURSIVE_GROUP rg ON child.parent_group_id = rg.account_source_id
    WHERE rg.hierarchy_level < 10   -- garde-fou anti-cycle infini
)
SELECT
    rg.root_group_id,
    rg.account_source_id,
    rg.customer_source_id,
    rg.hierarchy_level,
    rg.hierarchy_path,
    fe.outstanding_balance,
    fe.credit_limit,
    fe.date_key
FROM RECURSIVE_GROUP rg
INNER JOIN curated.dim_customer dc
    ON dc.customer_source_id = rg.customer_source_id AND dc.is_current = 1
LEFT JOIN curated.fact_exposure fe
    ON fe.customer_key = dc.customer_key
;
GO

-- Exemple d'usage : exposition totale consolidée par groupe racine, à la dernière date connue
-- SELECT root_group_id, date_key, SUM(outstanding_balance) AS total_group_exposure
-- FROM curated.vw_group_exposure_hierarchy
-- WHERE date_key = (SELECT MAX(date_key) FROM curated.fact_exposure)
-- GROUP BY root_group_id, date_key
-- ORDER BY total_group_exposure DESC;
