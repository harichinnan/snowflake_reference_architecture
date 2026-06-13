-- =============================================================================
-- denial_event.sql
-- Layer: SILVER_CANONICAL (canonical entity)
-- Grain: one row per (claim_id, denial_reason_code, denial_ts) denial event.
--
-- Purpose
--   Unified denial event stream. Denials surface from two places:
--     1. A current claim whose claim_status = 'DENIED' (header-level denial).
--     2. An adjudication event with event_type = 'DENIED' (processing-level
--        denial, possibly one of several on a claim's lifecycle).
--   Both are normalized to a common shape and the denial reason is enriched
--   from ref_denial_reason (reason name + category).
--
-- Keys
--   denial_event_sk -- surrogate over (claim_id, denial_reason_code, denial_ts, denial_source).
-- =============================================================================

{{
  config(
    materialized   = 'incremental',
    incremental_strategy = 'merge',
    unique_key     = 'denial_event_sk',
    on_schema_change = 'append_new_columns',
    tags           = ['silver', 'canonical', 'entity', 'denial']
  )
}}

-- Source 1: header-level denials on current valid claims.
with claim_denials as (

    select
        claim_id,
        claim_version,
        denial_reason_code,
        -- Use received/paid context as the denial timestamp proxy.
        coalesce(business_event_ts, received_date::timestamp_ntz)      as denial_ts,
        'CLAIM_HEADER'                                                 as denial_source,
        source_system, batch_id, load_id, pipeline_run_id, payload_hash
    from {{ ref('int_current_valid_claims') }}
    where is_current = true
      and upper(claim_status) = 'DENIED'

    {% if is_incremental() %}
      and {{ incremental_watermark_filter('ingest_ts') }}
    {% endif %}

),

-- Source 2: adjudication DENIED events.
adjud_denials as (

    select
        claim_id,
        new_claim_version                                             as claim_version,
        denial_reason_code,
        event_ts                                                      as denial_ts,
        'ADJUDICATION'                                                as denial_source,
        source_system, batch_id, load_id, pipeline_run_id, payload_hash
    from {{ ref('adjudication_event') }}
    where upper(event_type) = 'DENIED'

),

unioned as (
    select * from claim_denials
    union all
    select * from adjud_denials
),

-- Reference enrichment: denial reason name + category.
denial_ref as (
    select
        denial_reason_code,
        denial_reason_name,
        denial_category
    from {{ ref('ref_denial_reason') }}
)

select
    u.claim_id,
    u.claim_version,
    u.denial_reason_code,
    r.denial_reason_name,
    r.denial_category,
    u.denial_ts,
    u.denial_source,

    {{ generate_surrogate_key(['u.claim_id', 'u.denial_reason_code', 'u.denial_ts', 'u.denial_source']) }} as denial_event_sk,
    {{ generate_surrogate_key(['u.claim_id', 'u.claim_version']) }}    as claim_header_sk,

    true                                                              as is_current,
    coalesce(u.denial_ts, current_timestamp())                       as effective_from,
    cast(null as timestamp_ntz)                                      as effective_to,

    u.source_system,
    u.batch_id,
    u.load_id,
    u.pipeline_run_id,
    u.payload_hash,
    current_timestamp()                                              as created_at,
    current_timestamp()                                              as updated_at

from unioned u
left join denial_ref r
    on u.denial_reason_code = r.denial_reason_code
