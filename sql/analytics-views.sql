-- ============================================================
-- QA Tester — Analytics Views
-- Quality KPIs computed from test runs, results, bugs and releases.
-- Run after schema.sql:
--   psql -h localhost -U qatester -d qatester -f analytics.sql
-- Safe to re-run (CREATE OR REPLACE).
-- ============================================================

-- ============================================================
-- 1. PLATFORM QUALITY
-- One row per platform: test volume, pass rate, defect density
-- (bugs per 100 executed checks) and critical-bug share.
-- ============================================================
CREATE OR REPLACE VIEW v_platform_quality AS
WITH runs AS (
  SELECT p.type AS platform,
         COUNT(*)                         AS completed_runs,
         SUM(r.passed)                    AS passed,
         SUM(r.failed)                    AS failed,
         SUM(r.passed + r.failed)         AS executed
  FROM test_runs r
  JOIN projects p ON p.id = r.project_id
  WHERE r.status = 'completed'
  GROUP BY p.type
),
bug_counts AS (
  SELECT p.type AS platform,
         COUNT(*)                                              AS bugs,
         COUNT(*) FILTER (WHERE b.severity = 'critical')       AS critical_bugs,
         COUNT(*) FILTER (WHERE b.status IN ('open', 'in_progress')) AS open_bugs
  FROM bugs b
  JOIN projects p ON p.id = b.project_id
  GROUP BY p.type
)
SELECT COALESCE(r.platform, bc.platform)                              AS platform,
       COALESCE(r.completed_runs, 0)                                  AS completed_runs,
       COALESCE(r.executed, 0)                                        AS executed_checks,
       ROUND(100.0 * r.passed / NULLIF(r.executed, 0), 1)             AS pass_rate_pct,
       COALESCE(bc.bugs, 0)                                           AS bugs,
       COALESCE(bc.open_bugs, 0)                                      AS open_bugs,
       ROUND(100.0 * bc.bugs / NULLIF(r.executed, 0), 1)              AS defects_per_100_checks,
       ROUND(100.0 * bc.critical_bugs / NULLIF(bc.bugs, 0), 1)        AS critical_share_pct
FROM runs r
FULL OUTER JOIN bug_counts bc ON bc.platform = r.platform;

-- ============================================================
-- 2. BUG RESOLUTION BY SEVERITY
-- Median / P90 hours to fix, fix-to-verify lag, and SLA hit rate.
-- SLA targets: critical 24h, high 72h, medium 7d, low 14d.
-- ============================================================
CREATE OR REPLACE VIEW v_bug_resolution AS
WITH sla AS (
  SELECT * FROM (VALUES
    ('critical', 24, 1), ('high', 72, 2), ('medium', 168, 3), ('low', 336, 4)
  ) AS s(severity, sla_hours, sort_order)
),
timed AS (
  SELECT b.severity,
         b.status,
         EXTRACT(EPOCH FROM (b.fixed_at - b.found_at)) / 3600.0     AS hours_to_fix,
         EXTRACT(EPOCH FROM (b.verified_at - b.fixed_at)) / 3600.0  AS hours_to_verify
  FROM bugs b
)
SELECT s.severity,
       s.sla_hours,
       COUNT(t.severity)                                                        AS bugs,
       COUNT(t.hours_to_fix)                                                    AS fixed,
       COUNT(*) FILTER (WHERE t.status IN ('open', 'in_progress'))              AS still_open,
       COUNT(*) FILTER (WHERE t.status = 'deferred')                            AS deferred,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY t.hours_to_fix))::numeric, 1) AS median_hours_to_fix,
       ROUND((PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY t.hours_to_fix))::numeric, 1) AS p90_hours_to_fix,
       ROUND(AVG(t.hours_to_verify)::numeric, 1)                                AS avg_hours_to_verify,
       ROUND(100.0 * COUNT(*) FILTER (WHERE t.hours_to_fix <= s.sla_hours)
             / NULLIF(COUNT(t.hours_to_fix), 0), 1)                             AS within_sla_pct
FROM sla s
LEFT JOIN timed t ON t.severity = s.severity
GROUP BY s.severity, s.sla_hours, s.sort_order
ORDER BY s.sort_order;

-- ============================================================
-- 3. HEALTH SCORE TREND
-- Every completed run per project, with change vs the previous run
-- and a 3-run rolling average.
-- ============================================================
CREATE OR REPLACE VIEW v_health_trend AS
SELECT r.id                                                         AS run_id,
       p.id                                                         AS project_id,
       p.name                                                       AS project_name,
       p.type                                                       AS platform,
       r.completed_at,
       ROW_NUMBER() OVER w                                          AS run_number,
       r.health_score,
       r.health_score - LAG(r.health_score) OVER w                  AS change_vs_prev,
       ROUND(AVG(r.health_score) OVER (w ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 1) AS rolling_avg_3,
       ROUND(100.0 * r.passed / NULLIF(r.passed + r.failed, 0), 1)  AS pass_rate_pct,
       r.health_score >= 85                                         AS meets_gate_score
FROM test_runs r
JOIN projects p ON p.id = r.project_id
WHERE r.status = 'completed'
WINDOW w AS (PARTITION BY p.id ORDER BY r.completed_at);

-- ============================================================
-- 4. MOST FAILED CHECKS
-- Checklist items that fail most often (min 3 executions),
-- ranked within each platform.
-- ============================================================
CREATE OR REPLACE VIEW v_failing_checks AS
WITH agg AS (
  SELECT p.type                                        AS platform,
         tr.checklist_item_id,
         COUNT(*) FILTER (WHERE tr.status <> 'skip')   AS executions,
         COUNT(*) FILTER (WHERE tr.status = 'fail')    AS failures,
         COUNT(*) FILTER (WHERE tr.status = 'skip')    AS skips
  FROM test_results tr
  JOIN test_runs r ON r.id = tr.run_id
  JOIN projects p  ON p.id = r.project_id
  GROUP BY p.type, tr.checklist_item_id
)
SELECT platform,
       checklist_item_id,
       executions,
       failures,
       skips,
       ROUND(100.0 * failures / NULLIF(executions, 0), 1)  AS fail_rate_pct,
       DENSE_RANK() OVER (PARTITION BY platform
                          ORDER BY failures::numeric / NULLIF(executions, 0) DESC NULLS LAST) AS rank_in_platform
FROM agg
WHERE executions >= 3 AND failures > 0;

-- ============================================================
-- 5. WEEKLY BUG FLOW
-- Bugs opened vs closed per week and the running open backlog.
-- ============================================================
CREATE OR REPLACE VIEW v_weekly_bug_flow AS
WITH bounds AS (
  SELECT DATE_TRUNC('week', MIN(found_at)) AS first_week,
         DATE_TRUNC('week', NOW())         AS last_week
  FROM bugs
),
weeks AS (
  SELECT GENERATE_SERIES(first_week, last_week, INTERVAL '1 week') AS week
  FROM bounds
  WHERE first_week IS NOT NULL
),
opened AS (
  SELECT DATE_TRUNC('week', found_at) AS week, COUNT(*) AS n
  FROM bugs GROUP BY 1
),
closed AS (
  SELECT DATE_TRUNC('week', COALESCE(verified_at, fixed_at)) AS week, COUNT(*) AS n
  FROM bugs
  WHERE status IN ('fixed', 'verified')
  GROUP BY 1
)
SELECT w.week::date                                        AS week_start,
       COALESCE(o.n, 0)                                    AS opened,
       COALESCE(c.n, 0)                                    AS closed,
       SUM(COALESCE(o.n, 0) - COALESCE(c.n, 0))
         OVER (ORDER BY w.week)                            AS open_backlog
FROM weeks w
LEFT JOIN opened o ON o.week = w.week
LEFT JOIN closed c ON c.week = w.week;

-- ============================================================
-- 6. RELEASE GATE SUMMARY
-- How many QA cycles each release needed before it passed the gate,
-- and how many bugs were caught before shipping.
-- ============================================================
CREATE OR REPLACE VIEW v_release_summary AS
WITH ordered AS (
  SELECT rl.*,
         LAG(rl.approved_at) OVER (PARTITION BY rl.project_id ORDER BY rl.approved_at) AS prev_release_at
  FROM releases rl
)
SELECT o.id                                                  AS release_id,
       p.name                                                AS project_name,
       p.type                                                AS platform,
       o.version,
       o.approved_at,
       o.health_score,
       o.bugs_found,
       o.bugs_resolved,
       o.bugs_deferred,
       (SELECT COUNT(*) FROM test_runs r
         WHERE r.project_id = o.project_id
           AND r.status = 'completed'
           AND r.completed_at <= o.approved_at
           AND (o.prev_release_at IS NULL OR r.completed_at > o.prev_release_at)) AS cycles_to_release,
       ROUND(100.0 * o.passed_checks / NULLIF(o.total_checks, 0), 1)             AS final_pass_rate_pct
FROM ordered o
JOIN projects p ON p.id = o.project_id;

SELECT 'Analytics views applied successfully' AS status;
