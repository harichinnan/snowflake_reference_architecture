-- =============================================================================
-- gold_data_quality_summary.sql
-- Layer: GOLD (CERTIFIED operational data product)
--
-- Business question: "Which DQ checks failed most recently, and how much data is
-- quarantined?" The operational health product surfaced to MCP/Cortex.
--
-- GRAIN: one row per (model_name, test_name) for the LATEST DQ run, unioned
--   with quarantine rollups by (model_name, quarantine_reason, status).
--
-- Sources (AUDIT schema operational tables -- referenced via source(), resolved
--   from project vars audit_schema / audit_data_quality_result /
--   audit_quarantine_record):
--     AUDIT.DATA_QUALITY_RESULT  -- per-test pass/fail history
--     AUDIT.QUARANTINE_RECORD    -- rows routed out of the happy path
--
-- These are AUDIT.* operational tables created by snowflake/setup/009, not dbt
-- models, so we reference them as sources (see schema.yml sources block).
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags = ['gold', 'mart', 'operational', 'data_quality']
  )
}}

with dq as (

    select *
    from {{ source('audit', 'data_quality_result') }}

),

-- Latest DQ result per model/test.
latest_dq as (

    select
        'DQ_RESULT'                            as summary_type,
        model_name,
        test_name,
        dq_status,                             -- PASS | FAIL | WARN
        failed_record_count,
        executed_at                            as last_evaluated_at,
        null::string                           as quarantine_reason,
        null::number                           as quarantine_count
    from dq
    qualify row_number() over (
        partition by model_name, test_name
        order by executed_at desc
    ) = 1

),

quarantine as (

    select *
    from {{ source('audit', 'quarantine_record') }}

),

quarantine_rollup as (

    select
        'QUARANTINE'                           as summary_type,
        model_name,
        null::string                           as test_name,
        quarantine_status                      as dq_status,    -- OPEN | RESOLVED | REPROCESSED
        null::number                           as failed_record_count,
        max(quarantined_at)                    as last_evaluated_at,
        quarantine_reason,
        count(*)                               as quarantine_count
    from quarantine
    group by model_name, quarantine_status, quarantine_reason

),

unioned as (

    select
        summary_type, model_name, test_name, dq_status,
        failed_record_count, last_evaluated_at, quarantine_reason, quarantine_count
    from latest_dq

    union all

    select
        summary_type, model_name, test_name, dq_status,
        failed_record_count, last_evaluated_at, quarantine_reason, quarantine_count
    from quarantine_rollup

)

select * from unioned
order by last_evaluated_at desc nulls last
