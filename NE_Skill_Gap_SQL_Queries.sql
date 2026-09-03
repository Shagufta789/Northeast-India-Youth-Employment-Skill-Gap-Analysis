-- ============================================================================
-- Northeast India Youth Employment & Skill Gap Analysis
-- SQL analysis layer: cleaning -> segmentation -> gap calculation -> Skill Gap Index
-- Run against ne_employment.db (table: workforce_raw)
-- ============================================================================

-- 1. CLEAN: guard against nulls/negatives/duplicates (defensive even on clean data)
DROP TABLE IF EXISTS workforce_clean;
CREATE TABLE workforce_clean AS
SELECT DISTINCT
    TRIM(state) AS state,
    TRIM(sector) AS sector,
    TRIM(skill_category) AS skill_category,
    youth_population_lakhs,
    MAX(demand_jobs_2026_28, 0) AS demand_jobs,
    MAX(available_skilled_workforce, 0) AS available_workforce,
    ROUND(MIN(MAX(implementation_feasibility_score, 0), 1), 2) AS feasibility_score,
    avg_monthly_wage_inr AS avg_monthly_wage
FROM workforce_raw
WHERE state IS NOT NULL AND sector IS NOT NULL AND skill_category IS NOT NULL;

-- 2. SEGMENT + GAP: compute skill gap at state x sector x skill-category grain
DROP TABLE IF EXISTS skill_gap_detail;
CREATE TABLE skill_gap_detail AS
SELECT
    state,
    sector,
    skill_category,
    demand_jobs,
    available_workforce,
    (demand_jobs - available_workforce) AS skill_gap_jobs,
    ROUND(100.0 * (demand_jobs - available_workforce) / NULLIF(demand_jobs, 0), 1) AS skill_gap_pct,
    feasibility_score,
    avg_monthly_wage
FROM workforce_clean;

-- 3. SECTOR-LEVEL ROLLUP (across all states)
DROP TABLE IF EXISTS sector_summary;
CREATE TABLE sector_summary AS
SELECT
    sector,
    SUM(demand_jobs) AS total_demand,
    SUM(available_workforce) AS total_supply,
    SUM(demand_jobs - available_workforce) AS total_gap,
    ROUND(100.0 * SUM(demand_jobs - available_workforce) / NULLIF(SUM(demand_jobs), 0), 1) AS gap_pct,
    ROUND(AVG(feasibility_score), 2) AS avg_feasibility,
    ROUND(AVG(avg_monthly_wage), 0) AS avg_wage
FROM skill_gap_detail
GROUP BY sector
ORDER BY total_gap DESC;

-- 4. STATE-LEVEL ROLLUP (across all sectors)
DROP TABLE IF EXISTS state_summary;
CREATE TABLE state_summary AS
SELECT
    state,
    SUM(demand_jobs) AS total_demand,
    SUM(available_workforce) AS total_supply,
    SUM(demand_jobs - available_workforce) AS total_gap,
    ROUND(100.0 * SUM(demand_jobs - available_workforce) / NULLIF(SUM(demand_jobs), 0), 1) AS gap_pct
FROM skill_gap_detail
GROUP BY state
ORDER BY total_gap DESC;

-- 5. STATE x SECTOR ROLLUP (for the priority matrix)
DROP TABLE IF EXISTS state_sector_summary;
CREATE TABLE state_sector_summary AS
SELECT
    state,
    sector,
    SUM(demand_jobs) AS total_demand,
    SUM(available_workforce) AS total_supply,
    SUM(demand_jobs - available_workforce) AS total_gap,
    ROUND(100.0 * SUM(demand_jobs - available_workforce) / NULLIF(SUM(demand_jobs), 0), 1) AS gap_pct,
    ROUND(AVG(feasibility_score), 2) AS avg_feasibility
FROM skill_gap_detail
GROUP BY state, sector;

-- 6. SKILL GAP INDEX (SGI)
-- SGI = 0.45*normalized_gap_pct + 0.35*normalized_demand_volume + 0.20*normalized_feasibility
-- Higher SGI = higher priority for intervention (large gap, large opportunity, feasible to act on)
DROP TABLE IF EXISTS skill_gap_index;
CREATE TABLE skill_gap_index AS
WITH bounds AS (
    SELECT
        MIN(gap_pct) AS min_gap, MAX(gap_pct) AS max_gap,
        MIN(total_demand) AS min_dem, MAX(total_demand) AS max_dem,
        MIN(avg_feasibility) AS min_feas, MAX(avg_feasibility) AS max_feas
    FROM state_sector_summary
)
SELECT
    s.state,
    s.sector,
    s.total_demand,
    s.total_supply,
    s.total_gap,
    s.gap_pct,
    s.avg_feasibility,
    ROUND(
        0.45 * (1.0 * (s.gap_pct - b.min_gap) / NULLIF(b.max_gap - b.min_gap, 0)) +
        0.35 * (1.0 * (s.total_demand - b.min_dem) / NULLIF(b.max_dem - b.min_dem, 0)) +
        0.20 * (1.0 * (s.avg_feasibility - b.min_feas) / NULLIF(b.max_feas - b.min_feas, 0))
    , 3) AS skill_gap_index
FROM state_sector_summary s CROSS JOIN bounds b
ORDER BY skill_gap_index DESC;

-- 7. TOP PRIORITY SEGMENTS (Top 10 by SGI) -- headline output for intervention targeting
DROP TABLE IF EXISTS top_priority_segments;
CREATE TABLE top_priority_segments AS
SELECT state, sector, total_demand, total_supply, total_gap, gap_pct, avg_feasibility, skill_gap_index
FROM skill_gap_index
ORDER BY skill_gap_index DESC
LIMIT 10;

-- 8. SKILL-CATEGORY LEVEL GAPS (which specific skills are scarcest, across NE region)
DROP TABLE IF EXISTS skill_category_summary;
CREATE TABLE skill_category_summary AS
SELECT
    skill_category,
    SUM(demand_jobs) AS total_demand,
    SUM(available_workforce) AS total_supply,
    SUM(demand_jobs - available_workforce) AS total_gap,
    ROUND(100.0 * SUM(demand_jobs - available_workforce) / NULLIF(SUM(demand_jobs), 0), 1) AS gap_pct
FROM skill_gap_detail
GROUP BY skill_category
ORDER BY total_gap DESC;
