-- =============================================================================
-- provider.sql
-- Layer: SILVER_CANONICAL (canonical entity)
-- Grain: one row per NPI (current master record).
--
-- Purpose
--   Provider master entity. Billing / rendering / facility roles are recorded
--   as NPIs ON the claim (see claim_header); this model is the single source of
--   truth for the provider's attributes (name, specialty, taxonomy, type).
--
--   NPIs are normalized (trimmed, left-padded to 10 digits) and deduped to the
--   most recently extracted provider event per NPI.
--
-- Keys
--   npi          -- source natural key (normalized, preserved).
--   provider_sk  -- surrogate over the normalized npi.
-- =============================================================================

{{
  config(
    materialized   = 'incremental',
    incremental_strategy = 'merge',
    unique_key     = 'provider_sk',
    on_schema_change = 'append_new_columns',
    tags           = ['silver', 'canonical', 'entity', 'provider']
  )
}}

with provider_events as (

    select
        -- Normalize NPI: trim whitespace; left-pad numeric NPIs to 10 chars.
        lpad(trim({{ variant_value('payload', 'npi', 'string') }}), 10, '0') as npi,
        {{ variant_value('payload', 'provider_name', 'string') }}      as provider_name,
        {{ variant_value('payload', 'specialty', 'string') }}          as specialty,
        {{ variant_value('payload', 'taxonomy_code', 'string') }}      as taxonomy_code,
        {{ variant_value('payload', 'provider_type', 'string') }}      as provider_type,
        -- Keep the addresses array as VARIANT; address normalization is a
        -- downstream concern (bridge table), not part of the master grain.
        payload:addresses                                              as addresses_raw,
        source_system,
        source_extract_ts,
        ingest_ts,
        business_event_ts,
        payload_hash,
        batch_id,
        load_id,
        pipeline_run_id
    from {{ ref('br_raw_provider_event') }}
    where record_status = 'VALID'
      and {{ variant_value('payload', 'npi', 'string') }} is not null

),

current_provider as (

    select *
    from provider_events
    -- Most recent extract wins per NPI.
    qualify row_number() over (
        partition by npi
        order by source_extract_ts desc, ingest_ts desc
    ) = 1

)

select
    npi,
    provider_name,
    specialty,
    taxonomy_code,
    provider_type,
    addresses_raw,

    -- ---- surrogate + audit --------------------------------------------------
    {{ generate_surrogate_key(['npi']) }}                              as provider_sk,
    true                                                               as is_current,
    coalesce(business_event_ts, current_timestamp())                  as effective_from,
    cast(null as timestamp_ntz)                                       as effective_to,

    source_system,
    batch_id,
    load_id,
    pipeline_run_id,
    payload_hash,
    current_timestamp()                                               as created_at,
    current_timestamp()                                               as updated_at

from current_provider
