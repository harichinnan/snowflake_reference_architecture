-- =============================================================================
-- analysis: claims_quality_dashboard.sql
-- Layer: GOLD / AUDIT (read-only analysis -- compiled, not materialized)
--
-- Purpose
--   Query templates that back a "Claims Data Quality" dashboard. They read the
--   curated gold_data_quality_summary model together with the raw AUDIT tables
--   (DCM Domain E -- Data Quality, F -- Quarantine, I -- SLA/Freshness) so an
--   analyst can drop any block into a BI tool / worksheet.
--
--   dbt compiles analyses but never runs them; use `dbt compile` and copy the
--   compiled SQL from target/compiled/... into Snowflake.
--
-- DCM domains exercised: E (Data Quality), F (Quarantine), I (Freshness/SLA).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Failed / warning tests in the last 7 days (most recent run per test).
--    Sourced from the curated gold summary which already rolls up per test.
-- -----------------------------------------------------------------------------
with recent_dq as (

    select
        dq_run_ts,
        model_name,
        test_name,
        severity,                       -- 'error' | 'warn'
        status,                         -- 'pass' | 'fail'
        failed_row_count,
        dcm_domain                      -- A..J classification carried on the summary
    from {{ ref('gold_data_quality_summary') }}
    where dq_run_ts >= dateadd('day', -7, current_timestamp())

)

select
    model_name,
    test_name,
    severity,
    dcm_domain,
    failed_row_count,
    dq_run_ts
from recent_dq
where status = 'fail'
qualify row_number() over (
    partition by model_name, test_name
    order by dq_run_ts desc
) = 1
order by severity desc, failed_row_count desc
;

-- -----------------------------------------------------------------------------
-- 2. Quarantine volume by reason (DCM Domain F). Rows the pipeline routed off
--    the happy path -- a high count for a single reason signals a contract or
--    source problem. Reads the AUDIT source directly for reason-level detail.
-- -----------------------------------------------------------------------------
select
    quarantine_reason,
    source_batch_id,
    count(*)                              as quarantined_rows,
    min(quarantined_at)                   as first_seen,
    max(quarantined_at)                   as last_seen
from {{ source('audit', 'quarantine_record') }}
where quarantined_at >= dateadd('day', -30, current_timestamp())
group by quarantine_reason, source_batch_id
order by quarantined_rows desc
;

-- -----------------------------------------------------------------------------
-- 3. Pipeline freshness / SLA status (DCM Domain I). One row per pipeline with
--    its current freshness state and lag against the SLA. 'BREACH' rows are the
--    actionable ones for the dashboard's red banner.
-- -----------------------------------------------------------------------------
select
    pipeline_name,
    freshness_status,                     -- 'OK' | 'WARN' | 'BREACH'
    lag_hours,
    max_allowed_lag_hours,
    last_evaluated_at,
    last_loaded_at
from {{ source('control', 'pipeline_freshness_status') }}
order by
    case freshness_status
        when 'BREACH' then 0
        when 'WARN'   then 1
        else 2
    end,
    lag_hours desc
;

-- -----------------------------------------------------------------------------
-- 4. DQ pass-rate trend (last 30 days) -- a single KPI tile for the dashboard.
-- -----------------------------------------------------------------------------
select
    date_trunc('day', dq_run_ts)                                       as dq_day,
    count(*)                                                           as tests_run,
    count_if(status = 'pass')                                          as tests_passed,
    round(div0(count_if(status = 'pass'), count(*)) * 100, 2)          as pass_rate_pct
from {{ ref('gold_data_quality_summary') }}
where dq_run_ts >= dateadd('day', -30, current_timestamp())
group by 1
order by 1
;
