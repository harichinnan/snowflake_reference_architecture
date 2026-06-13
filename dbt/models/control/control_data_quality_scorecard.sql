-- =============================================================================
-- control_data_quality_scorecard.sql
-- CONTROL :: data-quality scorecard aggregated from AUDIT.DATA_QUALITY_RESULT.
--
-- DCM Domain E (Data Quality). Rolls up per-test results by
-- model_name / test_name / severity / status, attaching the latest run, pass /
-- fail counts, the most recent failed_row_count, and a simple trend (this run's
-- failed rows vs. the prior run's) so reviewers can see whether quality is
-- improving or regressing.
-- =============================================================================

{{ config(materialized='table', tags=['control', 'dcm_e_data_quality']) }}

with dq as (

    select
        model_name,
        test_name,
        severity,           -- e.g. WARN / ERROR
        status,             -- e.g. PASS / FAIL
        failed_row_count,
        run_id,
        run_completed_at
    from {{ source('audit', 'data_quality_result') }}

),

-- Per (model, test) ordering to isolate latest + prior run for the trend.
ordered as (

    select
        *,
        row_number() over (
            partition by model_name, test_name
            order by run_completed_at desc
        ) as run_rank
    from dq

),

latest as (
    select model_name, test_name, severity, status as latest_status,
           failed_row_count as latest_failed_row_count, run_id as latest_run_id,
           run_completed_at as latest_run_at
    from ordered
    where run_rank = 1
),

prior as (
    select model_name, test_name,
           failed_row_count as prior_failed_row_count
    from ordered
    where run_rank = 2
),

-- Historical aggregate counts across all runs per (model, test).
agg as (
    select
        model_name,
        test_name,
        count(*)                          as total_runs,
        count_if(status = 'PASS')         as pass_count,
        count_if(status = 'FAIL')         as fail_count,
        max(failed_row_count)             as max_failed_row_count
    from dq
    group by 1, 2
)

select
    l.model_name,
    l.test_name,
    l.severity,
    l.latest_status,
    l.latest_failed_row_count,
    l.latest_run_id,
    l.latest_run_at,

    a.total_runs,
    a.pass_count,
    a.fail_count,
    round(a.pass_count / nullif(a.total_runs, 0), 4) as pass_rate,
    a.max_failed_row_count,

    p.prior_failed_row_count,
    -- Trend: negative = fewer failing rows than last run (improving).
    (coalesce(l.latest_failed_row_count, 0) - coalesce(p.prior_failed_row_count, 0))
        as failed_row_trend,
    case
        when p.prior_failed_row_count is null then 'NEW'
        when coalesce(l.latest_failed_row_count, 0) < coalesce(p.prior_failed_row_count, 0) then 'IMPROVING'
        when coalesce(l.latest_failed_row_count, 0) > coalesce(p.prior_failed_row_count, 0) then 'REGRESSING'
        else 'STABLE'
    end as trend_direction
from latest l
left join agg   a on l.model_name = a.model_name and l.test_name = a.test_name
left join prior p on l.model_name = p.model_name and l.test_name = p.test_name
