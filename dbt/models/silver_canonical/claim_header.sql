-- =============================================================================
-- claim_header.sql
-- Layer: SILVER_CANONICAL (canonical entity)
-- Grain: one row per CURRENT VALID claim (header grain) -> one row per claim_id.
--
-- Purpose
--   The conformed claim header. Reads the current-state resolver
--   (int_current_valid_claims) and keeps only the live version of each claim
--   (is_current = true) -- voided / reversed / superseded versions are excluded.
--   Enriched with late-arrival flags and validated against reference seeds.
--
-- Keys
--   claim_id           -- natural key (unique at this grain among current rows).
--   claim_header_sk    -- surrogate over (claim_id, claim_version).
-- =============================================================================

{{
  config(
    materialized   = 'incremental',
    incremental_strategy = 'merge',
    unique_key     = 'claim_header_sk',
    on_schema_change = 'append_new_columns',
    tags           = ['silver', 'canonical', 'entity', 'claim', 'header']
  )
}}

with current_claims as (

    select *
    from {{ ref('int_current_valid_claims') }}
    -- Header grain = the single live version per claim_id.
    where is_current = true

    {% if is_incremental() %}
      and {{ incremental_watermark_filter('ingest_ts') }}
    {% endif %}

),

late as (
    select
        claim_id,
        claim_version,
        late_arrival_flag,
        impacted_period
    from {{ ref('int_late_arriving_claims') }}
)

select
    -- ---- identity --------------------------------------------------------
    c.claim_id,
    c.claim_version,

    -- ---- party keys ------------------------------------------------------
    c.member_id,
    c.payer_id,
    c.plan_id,

    -- ---- classification --------------------------------------------------
    c.claim_type,
    c.claim_status,

    -- ---- service / financial dates ---------------------------------------
    c.service_from_date,
    c.service_to_date,
    c.received_date,
    c.paid_date,

    -- ---- provider roles --------------------------------------------------
    c.billing_provider_npi,
    c.rendering_provider_npi,
    c.facility_npi,

    -- ---- money -----------------------------------------------------------
    c.total_charge_amount,
    c.allowed_amount,
    c.paid_amount,
    c.patient_responsibility,
    c.denial_reason_code,

    -- ---- lifecycle flags (from adjustment chain) -------------------------
    c.is_void,
    c.is_reversal,
    c.is_adjustment,
    c.adjustment_type,
    c.adjustment_reason,
    c.original_claim_id,
    c.supersedes_claim_id,

    -- ---- late arrival ----------------------------------------------------
    coalesce(l.late_arrival_flag, false)                               as late_arrival_flag,
    l.impacted_period,

    -- ---- surrogate + audit ----------------------------------------------
    {{ generate_surrogate_key(['c.claim_id', 'c.claim_version']) }}    as claim_header_sk,
    c.is_current,
    coalesce(c.effective_from_ts, c.business_event_ts)                 as effective_from,
    cast(null as timestamp_ntz)                                       as effective_to,

    c.source_system,
    c.batch_id,
    c.load_id,
    c.pipeline_run_id,
    c.payload_hash,
    current_timestamp()                                               as created_at,
    current_timestamp()                                               as updated_at

from current_claims c
left join late l
    on  c.claim_id      = l.claim_id
    and c.claim_version = l.claim_version
