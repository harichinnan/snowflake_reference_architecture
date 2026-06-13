-- =============================================================================
-- control_freshness_status.sql
-- CONTROL :: per-pipeline freshness evaluation.
--
-- DCM Domain I (SLA / Freshness). Computes, per pipeline, the freshness of the
-- bronze landing data (latest ingest_ts and latest source_extract_ts) against
-- the configured max_allowed_lag_hours from CONTROL.PIPELINE_CONFIG (falling
-- back to any pre-materialized CONTROL.PIPELINE_FRESHNESS_STATUS thresholds).
--
-- Outputs a freshness_status (FRESH / STALE / BREACH) and an alert_severity so
-- monitoring / workbooks can drive SLA alerts.
--
-- Thresholds:
--   FRESH  : lag_hours <= max_allowed_lag_hours
--   STALE  : max_allowed_lag_hours < lag_hours <= 2 * max_allowed_lag_hours
--   BREACH : lag_hours > 2 * max_allowed_lag_hours
-- =============================================================================

{{ config(materialized='table', tags=['control', 'dcm_i_sla']) }}

-- Per-pipeline observed freshness from the bronze event models. Each pipeline
-- name matches the post-hook pipeline_name used in the bronze models.
with observed as (

    select 'bronze.br_raw_claim_event'        as pipeline_name, max(ingest_ts) as latest_ingest_ts, max(source_extract_ts) as latest_extract_ts, max(business_event_ts) as latest_event_ts from {{ ref('br_raw_claim_event') }}
    union all
    select 'bronze.br_raw_eligibility_event'  as pipeline_name, max(ingest_ts), max(source_extract_ts), max(business_event_ts) from {{ ref('br_raw_eligibility_event') }}
    union all
    select 'bronze.br_raw_provider_event'     as pipeline_name, max(ingest_ts), max(source_extract_ts), max(business_event_ts) from {{ ref('br_raw_provider_event') }}
    union all
    select 'bronze.br_raw_pharmacy_event'     as pipeline_name, max(ingest_ts), max(source_extract_ts), max(business_event_ts) from {{ ref('br_raw_pharmacy_event') }}
    union all
    select 'bronze.br_raw_adjudication_event' as pipeline_name, max(ingest_ts), max(source_extract_ts), max(business_event_ts) from {{ ref('br_raw_adjudication_event') }}

),

config as (

    select
        pipeline_name,
        max_allowed_lag_hours
    from {{ source('control', 'pipeline_config') }}

)

select
    o.pipeline_name,
    o.latest_ingest_ts,
    o.latest_extract_ts,
    o.latest_event_ts,

    -- Default SLA to 24h when the pipeline has no configured threshold.
    coalesce(c.max_allowed_lag_hours, 24) as max_allowed_lag_hours,

    -- Observed lag of the warehouse data behind "now".
    datediff('hour', o.latest_ingest_ts, current_timestamp())  as ingest_lag_hours,
    -- Lag of ingest behind the source extract (load latency).
    datediff('hour', o.latest_extract_ts, o.latest_ingest_ts)  as load_latency_hours,

    -- DCM I freshness verdict.
    case
        when datediff('hour', o.latest_ingest_ts, current_timestamp())
             <= coalesce(c.max_allowed_lag_hours, 24)               then 'FRESH'
        when datediff('hour', o.latest_ingest_ts, current_timestamp())
             <= 2 * coalesce(c.max_allowed_lag_hours, 24)           then 'STALE'
        else 'BREACH'
    end as freshness_status,

    case
        when datediff('hour', o.latest_ingest_ts, current_timestamp())
             <= coalesce(c.max_allowed_lag_hours, 24)               then 'NONE'
        when datediff('hour', o.latest_ingest_ts, current_timestamp())
             <= 2 * coalesce(c.max_allowed_lag_hours, 24)           then 'WARN'
        else 'CRITICAL'
    end as alert_severity,

    current_timestamp() as evaluated_at
from observed o
left join config c
    on o.pipeline_name = c.pipeline_name
