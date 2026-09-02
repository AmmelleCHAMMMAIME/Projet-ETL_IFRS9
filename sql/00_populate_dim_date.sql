/* ============================================================================
   PEUPLEMENT DE curated.dim_date
   Génère une plage de dates journalières (par défaut 2018-01-01 -> 2030-12-31)
   Prérequis pour toute jointure vers les tables de faits.
   ============================================================================ */

DECLARE @start_date DATE = '2018-01-01';
DECLARE @end_date   DATE = '2030-12-31';

;WITH n AS (
    SELECT 0 AS n
    UNION ALL
    SELECT n + 1 FROM n WHERE n < DATEDIFF(DAY, @start_date, @end_date)
)
INSERT INTO curated.dim_date (date_key, full_date, [year], [quarter], [month], month_name, is_reporting_period_end)
SELECT
    CAST(FORMAT(d, 'yyyyMMdd') AS INT),
    d,
    YEAR(d),
    DATEPART(QUARTER, d),
    MONTH(d),
    DATENAME(MONTH, d),
    CASE WHEN d = EOMONTH(d) THEN 1 ELSE 0 END
FROM (SELECT DATEADD(DAY, n, @start_date) AS d FROM n) x
OPTION (MAXRECURSION 0);
GO
