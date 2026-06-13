-- =============================================================================
-- adjudication_event.sql
-- Layer: SILVER_CANONICAL (canonical entity)
-- Grain: one row per adjudication_event_id (latest extract wins).
--
-- Purpose
--   Conformed adjudication event log from BR_RAW_ADJUDICATION_EVENT. Each row is
--   a discrete processing event against a claim (PAID, DENIED, ADJUSTED,
--   REVERSED, ...) capturing the version transition and the paid-amount delta.
--   Feeds denial_event and downstream financial-restatement analytics.
--
-- Keys
--   adjudication_event_id  -- natural key (preserved).
--   adjudication_sk        -- surrogate over adjudication_event_id.
-- =============================================================================

{{
  config(
    materialized   = 'incremental',
    incremental_strategy = 'merge',
    unique_key     = 'adjudication_sk',
    on_schema_change = 'append_new_columns',
    tags           = ['silver', 'canonical', 'entity', 'adjudication']
  )
}}

with bronze as (

    select *
    from {{ ref('br_raw_adjudication_event') }}
    where record_status = 'VALID'

    {% if is_incremental() %}
      and {{ incremental_watermark_filter('ingest_ts') }}
    {% endif %}

),

typed as (

    select
        {{ variant_value('payload', 'adjudication_event_id', 'string') }} as adjudication_event_id,
        {{ variant_value('payload', 'claim_id', 'string') }}           as claim_id,
        {{ variant_value('payload', 'event_type', 'string') }}         as event_type,
        {{ variant_value('payload', 'event_ts', 'timestamp') }}        as event_ts,
        {{ variant_value('payload', 'adjustment_type', 'string') }}    as adjustment_type,
        {{ variant_value('payload', 'adjustment_reason', 'string') }}  as adjustment_reason,
        {{ variant_value('payload', 'prior_claim_version', 'number') }} as prior_claim_version,
        {{ variant_value('payload', 'new_claim_version', 'number') }}  as new_claim_version,
        {{ variant_value('payload', 'denial_reason_code', 'string') }} as denial_reason_code,
        {{ variant_value('payload', 'paid_amount_delta', 'number') }}  as paid_amount_delta,
        source_system, source_extract_ts, ingest_ts, business_event_ts,
        payload_hash, batch_id, load_id, pipeline_run_id
    from bronze
    qualify row_number() over (
        partition by {{ variant_value('payload', 'adjudication_event_id', 'string') }}
        order by source_extract_ts desc, ingest_ts desc
    ) = 1

)

select
    t.adjudication_event_id,
    t.claim_id,
    t.event_type,
    t.event_ts,
    t.adjustment_type,
    t.adjustment_reason,
    t.prior_claim_version,
    t.new_claim_version,
    t.denial_reason_code,
    t.paid_amount_delta,

    {{ generate_surrogate_key(['t.adjudication_event_id']) }}         as adjudication_sk,
    true                                                              as is_current,
    coalesce(t.event_ts, t.business_event_ts, current_timestamp())   as effective_from,
    cast(null as timestamp_ntz)                                      as effective_to,

    t.source_system,
    t.batch_id,
    t.load_id,
    t.pipeline_run_id,
    t.payload_hash,
    current_timestamp()                                              as created_at,
    current_timestamp()                                              as updated_at

from typed t
