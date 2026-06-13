-- =============================================================================
-- claim_diagnosis.sql
-- Layer: SILVER_CANONICAL (canonical entity)
-- Grain: one row per (claim_id, diagnosis_position).
--
-- Purpose
--   Explode payload:diagnoses[] for each CURRENT VALID claim into a flat
--   diagnosis table (one row per diagnosis code on the claim), preserving
--   ordering (diagnosis_position) and POA. Diagnosis codes are validated
--   downstream against ref_diagnosis_code via a relationships test.
--
-- Keys
--   claim_diagnosis_sk -- surrogate over (claim_id, claim_version, diagnosis_position).
--   claim_header_sk    -- FK to claim_header.
-- =============================================================================

{{
  config(
    materialized   = 'incremental',
    incremental_strategy = 'merge',
    unique_key     = 'claim_diagnosis_sk',
    on_schema_change = 'append_new_columns',
    tags           = ['silver', 'canonical', 'entity', 'claim', 'diagnosis']
  )
}}

with current_claims as (

    select
        claim_id,
        claim_version,
        diagnoses_raw,
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
        d.value                                                        as dx,
        c.source_system, c.batch_id, c.load_id, c.pipeline_run_id, c.payload_hash,
        c.business_event_ts, c.is_current
    from current_claims c,
         lateral flatten(input => c.diagnoses_raw, outer => false) d

),

typed as (

    select
        f.claim_id,
        f.claim_version,
        {{ variant_value('dx', 'diagnosis_code', 'string') }}          as diagnosis_code,
        {{ variant_value('dx', 'diagnosis_position', 'number') }}      as diagnosis_position,
        {{ variant_value('dx', 'diagnosis_type', 'string') }}          as diagnosis_type,
        {{ variant_value('dx', 'present_on_admission', 'string') }}    as present_on_admission,
        f.source_system, f.batch_id, f.load_id, f.pipeline_run_id, f.payload_hash,
        f.business_event_ts, f.is_current
    from flattened f

)

select
    t.claim_id,
    t.claim_version,
    t.diagnosis_code,
    t.diagnosis_position,
    t.diagnosis_type,
    t.present_on_admission,

    {{ generate_surrogate_key(['t.claim_id', 't.claim_version', 't.diagnosis_position']) }} as claim_diagnosis_sk,
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
