-- =============================================================================
-- control_pipeline_watermark_status.sql
-- CONTROL :: per-pipeline watermark + lookback status projection.
--
-- DCM Domain C (Watermark) -- with B (Batch) context from the latest run.
-- Joins CONTROL.PIPELINE_CONFIG + CONTROL.WATERMARK_STATE + the latest
-- CONTROL.PIPELINE_RUN to show, per pipeline:
--   last_successful_watermark, prior_successful_watermark,
--   lookback_start_watermark (= last - lookback_days), lookback_days,
--   late_arrival_days, max_watermark_seen, and the lag between max seen and
--   the last successful watermark.
--
-- This is the operational view that explains *what window the next incremental
-- run will read* (last_successful_watermark - lookback_days).
-- =============================================================================

{{ config(materialized='table', tags=['control', 'dcm_c_watermark']) }}

with config as (

    select
        pipeline_name,
        coalesce(lookback_days, {{ var('lookback_default_days') }})        as lookback_days,
        coalesce(late_arrival_days, {{ var('late_arrival_default_days') }}) as late_arrival_days,
        watermark_column
    from {{ source('control', 'pipeline_config') }}

),

watermark as (

    select
        pipeline_name,
        last_successful_watermark,
        prior_successful_watermark
        -- NOTE: max_watermark_seen lives on CONTROL.PIPELINE_RUN, not on
        -- WATERMARK_STATE; it is sourced from latest_run below.
    from {{ source('control', 'watermark_state') }}

),

-- Latest run per pipeline for batch/run context (DCM B).
-- PIPELINE_RUN carries pipeline_run_id, run_status, started_at, completed_at,
-- and the max_watermark_seen observed during the run.
latest_run as (

    select
        pipeline_name,
        pipeline_run_id,
        run_status,
        started_at,
        completed_at,
        max_watermark_seen
    from {{ source('control', 'pipeline_run') }}
    qualify row_number() over (
        partition by pipeline_name
        order by coalesce(started_at, completed_at) desc
    ) = 1

)

select
    c.pipeline_name,

    -- Watermark state (DCM C)
    w.last_successful_watermark,
    w.prior_successful_watermark,
    -- The actual lower bound the next incremental will scan from.
    dateadd('day', -1 * c.lookback_days, w.last_successful_watermark)
        as lookback_start_watermark,
    c.lookback_days,
    c.late_arrival_days,
    r.max_watermark_seen,

    -- Lag: how far the freshest observed event is ahead of the committed
    -- watermark (rows seen but not yet promoted past the watermark).
    datediff('second', w.last_successful_watermark, r.max_watermark_seen)
        as watermark_lag_seconds,

    c.watermark_column,

    -- Latest run context (DCM B)
    r.pipeline_run_id as latest_run_id,
    r.run_status      as latest_run_status,
    r.started_at      as latest_run_started_at,
    r.completed_at    as latest_run_ended_at
from config c
left join watermark w
    on c.pipeline_name = w.pipeline_name
left join latest_run r
    on c.pipeline_name = r.pipeline_name
