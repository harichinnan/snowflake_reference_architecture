-- =============================================================================
-- int_late_arriving_claims.sql
-- Layer: SILVER_CANONICAL (intermediate)
-- Grain: one row per (claim_id, claim_version) -- mirrors the deduped set.
--
-- Purpose
--   Detect claims that arrived "late" relative to their service period, i.e.
--   the claim was received / ingested well after the service was rendered and
--   therefore likely lands in an accounting/reporting period that was already
--   closed. Gold incremental aggregates use these flags to decide whether a
--   prior period needs to be re-opened / restated.
--
--   Two notions of lateness are computed:
--     * received_lag_days  = received_date  - service_to_date
--     * ingest_lag_days    = ingest_ts(date) - service_to_date
--   A claim is late-arriving when the lag exceeds the configured grace window
--   (var late_arrival_default_days, default 7) AND it falls into a period that
--   precedes the period implied by its ingest timestamp.
--
--   impacted_period = the YYYY-MM period (first of month of service_to_date)
--   whose closed books are affected. Surfaced for restatement bookkeeping.
-- =============================================================================

{{
  config(
    materialized   = 'incremental',
    incremental_strategy = 'merge',
    unique_key     = ['claim_id', 'claim_version'],
    on_schema_change = 'append_new_columns',
    tags           = ['silver', 'canonical', 'claim', 'intermediate', 'late_arrival']
  )
}}

{# Grace window (in days) before a claim is considered late-arriving. #}
{% set grace_days = var('late_arrival_default_days', 7) %}

with deduped as (

    select *
    from {{ ref('int_claim_event_deduped') }}

    {% if is_incremental() %}
      where {{ incremental_watermark_filter('ingest_ts') }}
    {% endif %}

),

lagged as (

    select
        claim_id,
        claim_version,
        member_id,
        service_from_date,
        service_to_date,
        received_date,
        business_event_ts,
        ingest_ts,

        -- Lag of receipt vs. end of service. NULL-safe: if no service_to_date
        -- we cannot reason about lateness, treat as not-late.
        datediff('day', service_to_date, received_date)               as received_lag_days,
        datediff('day', service_to_date, ingest_ts::date)             as ingest_lag_days,

        -- The financial period (month grain) the service belongs to.
        date_trunc('month', service_to_date)                          as service_period,
        -- The period the row is *physically* landing in (ingest time).
        date_trunc('month', ingest_ts::date)                          as ingest_period

    from deduped

)

select
    claim_id,
    claim_version,
    member_id,
    service_from_date,
    service_to_date,
    received_date,
    received_lag_days,
    ingest_lag_days,
    service_period,
    ingest_period,

    -- Late-arrival flag: receipt lag beyond grace AND the service period is
    -- strictly before the period the row landed in (a prior, likely-closed
    -- period). coalesce() guards NULL dates -> not late.
    case
        when service_to_date is null then false
        when coalesce(received_lag_days, 0) > {{ grace_days }}
             and service_period < ingest_period
            then true
        else false
    end                                                               as late_arrival_flag,

    -- The closed period impacted by this late arrival (NULL when not late).
    case
        when service_to_date is not null
             and coalesce(received_lag_days, 0) > {{ grace_days }}
             and service_period < ingest_period
            then service_period
        else null
    end                                                               as impacted_period,

    -- Carry the metadata the merge needs.
    business_event_ts,
    ingest_ts

from lagged
