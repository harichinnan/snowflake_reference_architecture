-- =============================================================================
-- claim_procedure.sql
-- Layer: SILVER_CANONICAL (canonical entity)
-- Grain: one row per (claim_id, procedure_position).
--
-- Purpose
--   Explode payload:procedures[] for each CURRENT VALID claim into a flat
--   header-level procedure table (distinct from claim_line procedures, which
--   are line-level). Preserves procedure ordering and the procedure date.
--   Procedure codes validate against ref_procedure_code downstream.
--
-- Keys
--   claim_procedure_sk -- surrogate over (claim_id, claim_version, procedure_position).
--   claim_header_sk    -- FK to claim_header.
-- =============================================================================

{{
  config(
    materialized   = 'incremental',
    incremental_strategy = 'merge',
    unique_key     = 'claim_procedure_sk',
    on_schema_change = 'append_new_columns',
    tags           = ['silver', 'canonical', 'entity', 'claim', 'procedure']
  )
}}

with current_claims as (

    select
        claim_id,
        claim_version,
        procedures_raw,
        source_system, batch_id, load_id, pipeline_run_id, payload_hash,
        business_event_ts, is_current, ingest_ts
    from {{ ref('int_current_valid_claims') }}
    where is_current = true

    {% if is_incremental() %}
      and {{ incremental_watermark_filter('ingest_ts') }}
    {% endif %}

),

flattened as (

    select
        c.claim_id,
        c.claim_version,
        p.value                                                        as proc,
        c.source_system, c.batch_id, c.load_id, c.pipeline_run_id, c.payload_hash,
        c.business_event_ts, c.is_current
    from current_claims c,
         lateral flatten(input => c.procedures_raw, outer => false) p

),

typed as (

    select
        f.claim_id,
        f.claim_version,
        {{ variant_value('proc', 'procedure_code', 'string') }}        as procedure_code,
        {{ variant_value('proc', 'procedure_position', 'number') }}    as procedure_position,
        {{ variant_value('proc', 'procedure_date', 'date') }}          as procedure_date,
        f.source_system, f.batch_id, f.load_id, f.pipeline_run_id, f.payload_hash,
        f.business_event_ts, f.is_current
    from flattened f

)

select
    t.claim_id,
    t.claim_version,
    t.procedure_code,
    t.procedure_position,
    t.procedure_date,

    {{ generate_surrogate_key(['t.claim_id', 't.claim_version', 't.procedure_position']) }} as claim_procedure_sk,
    {{ generate_surrogate_key(['t.claim_id', 't.claim_version']) }}    as claim_header_sk,

    t.is_current,
    coalesce(t.business_event_ts, current_timestamp())                as effective_from,
    cast(null as timestamp_ntz)                                       as effective_to,

    t.source_system,
    t.batch_id,
    t.load_id,
    t.pipeline_run_id,
    t.payload_hash,
    current_timestamp()                                               as created_at,
    current_timestamp()                                               as updated_at

from typed t
