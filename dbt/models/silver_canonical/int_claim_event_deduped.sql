-- =============================================================================
-- int_claim_event_deduped.sql
-- Layer: SILVER_CANONICAL (intermediate)
-- Grain: one row per (claim_id, claim_version) -- the latest extract wins.
--
-- Purpose
--   Bronze BR_RAW_CLAIM_EVENT is an append-only landing table: the same claim
--   version can land multiple times (re-extracts, replays, idempotent reloads).
--   This model:
--     1. Filters to VALID DCM rows only (record_status = 'VALID').
--     2. Projects the typed business fields out of the VARIANT `payload`.
--     3. Deduplicates each (claim_id, claim_version) keeping the most recent
--        physical arrival via QUALIFY ROW_NUMBER().
--
--   It does NOT yet resolve "which version is current" -- that is the job of
--   int_claim_adjustment_chain + int_current_valid_claims. Here we simply give
--   every distinct claim version exactly one clean, typed row.
--
-- Incremental
--   MERGE on the natural composite key. We re-pull a lookback window of bronze
--   rows (late-arriving / replayed extracts) and let MERGE upsert. Because the
--   dedupe is per (claim_id, claim_version), reprocessing the same key is safe.
-- =============================================================================

{{
  config(
    materialized   = 'incremental',
    incremental_strategy = 'merge',
    unique_key     = ['claim_id', 'claim_version'],
    on_schema_change = 'append_new_columns',
    tags           = ['silver', 'canonical', 'claim', 'intermediate']
  )
}}

with bronze as (

    select *
    from {{ ref('br_raw_claim_event') }}
    -- Only conformed, validated DCM records flow into canonical.
    where record_status = 'VALID'

    {% if is_incremental() %}
      -- Re-pull a lookback window so late-arriving re-extracts of an existing
      -- claim version are reconsidered. incremental_watermark_filter applies the
      -- pipeline lookback (CONTROL.PIPELINE_CONFIG / lookback_default_days) on the
      -- ingest_ts column.
      and {{ incremental_watermark_filter('ingest_ts') }}
    {% endif %}

),

typed as (

    select
        -- ---- business keys (from payload) -----------------------------------
        {{ variant_value('payload', 'claim_id', 'string') }}              as claim_id,
        {{ variant_value('payload', 'claim_version', 'number') }}         as claim_version,
        {{ variant_value('payload', 'member_id', 'string') }}             as member_id,
        {{ variant_value('payload', 'payer_id', 'string') }}              as payer_id,
        {{ variant_value('payload', 'plan_id', 'string') }}               as plan_id,

        -- ---- classification --------------------------------------------------
        {{ variant_value('payload', 'claim_type', 'string') }}            as claim_type,
        {{ variant_value('payload', 'claim_status', 'string') }}          as claim_status,

        -- ---- service / financial dates --------------------------------------
        {{ variant_value('payload', 'service_from_date', 'date') }}       as service_from_date,
        {{ variant_value('payload', 'service_to_date', 'date') }}         as service_to_date,
        {{ variant_value('payload', 'received_date', 'date') }}           as received_date,
        {{ variant_value('payload', 'paid_date', 'date') }}               as paid_date,

        -- ---- provider roles (NPIs live on the claim) ------------------------
        {{ variant_value('payload', 'billing_provider_npi', 'string') }}  as billing_provider_npi,
        {{ variant_value('payload', 'rendering_provider_npi', 'string') }} as rendering_provider_npi,
        {{ variant_value('payload', 'facility_npi', 'string') }}          as facility_npi,

        -- ---- money -----------------------------------------------------------
        {{ variant_value('payload', 'total_charge_amount', 'number') }}   as total_charge_amount,
        {{ variant_value('payload', 'allowed_amount', 'number') }}        as allowed_amount,
        {{ variant_value('payload', 'paid_amount', 'number') }}           as paid_amount,
        {{ variant_value('payload', 'patient_responsibility', 'number') }} as patient_responsibility,
        {{ variant_value('payload', 'denial_reason_code', 'string') }}    as denial_reason_code,

        -- ---- adjustment / lifecycle indicators ------------------------------
        {{ variant_value('payload', 'original_claim_id', 'string') }}     as original_claim_id,
        {{ variant_value('payload', 'adjustment_type', 'string') }}       as adjustment_type,
        {{ variant_value('payload', 'void_indicator', 'boolean') }}       as void_indicator,
        {{ variant_value('payload', 'reversal_indicator', 'boolean') }}   as reversal_indicator,
        {{ variant_value('payload', 'adjustment_reason', 'string') }}     as adjustment_reason,

        -- ---- keep the raw arrays for downstream FLATTEN models ---------------
        payload:diagnoses                                                  as diagnoses_raw,
        payload:procedures                                                 as procedures_raw,
        payload:lines                                                      as lines_raw,

        -- ---- DCM metadata carried forward unchanged -------------------------
        bronze_event_id,
        source_system,
        source_extract_ts,
        ingest_ts,
        business_event_ts,
        natural_key,
        payload_hash,
        batch_id,
        load_id,
        pipeline_run_id,
        record_status

    from bronze

)

select *
from typed
-- Keep the most recently extracted physical copy of each claim version.
-- source_extract_ts is the producer's extract time; ingest_ts breaks ties for
-- identical extract timestamps (idempotent replays).
qualify row_number() over (
    partition by claim_id, claim_version
    order by source_extract_ts desc, ingest_ts desc
) = 1
