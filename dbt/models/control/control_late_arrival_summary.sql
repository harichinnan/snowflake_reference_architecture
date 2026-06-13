-- =============================================================================
-- control_late_arrival_summary.sql
-- CONTROL :: late-arriving record summary across the bronze event models.
--
-- DCM Domain C (Watermark) / I (SLA) -- quantifies the late arrivals the
-- incremental lookback window is responsible for capturing. A record is "late"
-- when the source extracted / Snowflake ingested it materially after the
-- business event occurred, i.e. the event lands into an already-processed
-- prior period.
--
-- Grouped by source_system and the affected business month, with a count of
-- late arrivals and how stale they were. This links directly to the lookback
-- configuration surfaced by control_pipeline_watermark_status: late arrivals
-- beyond the lookback window are the ones that would be missed.
-- =============================================================================

{{ config(materialized='table', tags=['control', 'dcm_c_watermark', 'dcm_i_sla']) }}

-- Late-arrival threshold (days) between business_event_ts and source_extract_ts.
-- Defaults to the project late_arrival window; tune via --vars if needed.
{% set late_threshold_days = var('late_arrival_default_days', 7) %}

with unioned as (

    select 'claim_event'        as source_model, source_system, business_event_ts, source_extract_ts, ingest_ts from {{ ref('br_raw_claim_event') }}
    union all
    select 'eligibility_event'  as source_model, source_system, business_event_ts, source_extract_ts, ingest_ts from {{ ref('br_raw_eligibility_event') }}
    union all
    select 'provider_event'     as source_model, source_system, business_event_ts, source_extract_ts, ingest_ts from {{ ref('br_raw_provider_event') }}
    union all
    select 'pharmacy_event'     as source_model, source_system, business_event_ts, source_extract_ts, ingest_ts from {{ ref('br_raw_pharmacy_event') }}
    union all
    select 'adjudication_event' as source_model, source_system, business_event_ts, source_extract_ts, ingest_ts from {{ ref('br_raw_adjudication_event') }}

),

flagged as (

    select
        source_model,
        source_system,
        business_event_ts,
        source_extract_ts,
        ingest_ts,
        -- The business month the late record retroactively affects.
        date_trunc('month', business_event_ts)::date as affected_business_month,
        -- Days between the event happening and the source producing the extract.
        datediff('day', business_event_ts, source_extract_ts) as extract_lag_days,
        -- Days between the event happening and Snowflake ingesting it.
        datediff('day', business_event_ts, ingest_ts)         as ingest_lag_days,
        -- Late if the extract/ingest lag exceeds the threshold.
        (datediff('day', business_event_ts, source_extract_ts) > {{ late_threshold_days }}
         or datediff('day', business_event_ts, ingest_ts) > {{ late_threshold_days }})
            as is_late_arrival
    from unioned

)

select
    source_system,
    source_model,
    affected_business_month,
    count(*)                                                 as total_records,
    count_if(is_late_arrival)                                as late_arrival_count,
    -- Share of records in this affected period that arrived late.
    round(count_if(is_late_arrival) / nullif(count(*), 0), 4) as late_arrival_ratio,
    max(case when is_late_arrival then extract_lag_days end)  as max_extract_lag_days,
    avg(case when is_late_arrival then extract_lag_days end)  as avg_extract_lag_days,
    max(case when is_late_arrival then ingest_lag_days end)   as max_ingest_lag_days,
    {{ late_threshold_days }}                                 as late_threshold_days
from flagged
group by 1, 2, 3
having count_if(is_late_arrival) > 0
order by source_system, source_model, affected_business_month
