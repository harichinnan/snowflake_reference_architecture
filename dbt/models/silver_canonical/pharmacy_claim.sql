-- =============================================================================
-- pharmacy_claim.sql
-- Layer: SILVER_CANONICAL (canonical entity)
-- Grain: one row per pharmacy_claim_id (latest extract wins).
--
-- Purpose
--   Conformed pharmacy (Rx) claim entity from BR_RAW_PHARMACY_EVENT. Parallel to
--   medical claim_header but at the fill grain. Member, prescriber and pharmacy
--   NPIs link to patient / provider masters respectively.
--
-- Keys
--   pharmacy_claim_id  -- natural key (preserved).
--   pharmacy_claim_sk  -- surrogate over pharmacy_claim_id.
-- =============================================================================

{{
  config(
    materialized   = 'incremental',
    incremental_strategy = 'merge',
    unique_key     = 'pharmacy_claim_sk',
    on_schema_change = 'append_new_columns',
    tags           = ['silver', 'canonical', 'entity', 'pharmacy']
  )
}}

with bronze as (

    select *
    from {{ ref('br_raw_pharmacy_event') }}
    where record_status = 'VALID'

    {% if is_incremental() %}
      and {{ incremental_watermark_filter('ingest_ts') }}
    {% endif %}

),

typed as (

    select
        {{ variant_value('payload', 'pharmacy_claim_id', 'string') }}  as pharmacy_claim_id,
        {{ variant_value('payload', 'member_id', 'string') }}          as member_id,
        {{ variant_value('payload', 'ndc', 'string') }}                as ndc,
        {{ variant_value('payload', 'drug_name', 'string') }}          as drug_name,
        {{ variant_value('payload', 'days_supply', 'number') }}        as days_supply,
        {{ variant_value('payload', 'quantity_dispensed', 'number') }} as quantity_dispensed,
        {{ variant_value('payload', 'fill_date', 'date') }}            as fill_date,
        lpad(trim({{ variant_value('payload', 'prescriber_npi', 'string') }}), 10, '0') as prescriber_npi,
        lpad(trim({{ variant_value('payload', 'pharmacy_npi', 'string') }}), 10, '0')   as pharmacy_npi,
        {{ variant_value('payload', 'charge_amount', 'number') }}      as charge_amount,
        {{ variant_value('payload', 'allowed_amount', 'number') }}     as allowed_amount,
        {{ variant_value('payload', 'paid_amount', 'number') }}        as paid_amount,
        {{ variant_value('payload', 'patient_pay_amount', 'number') }} as patient_pay_amount,
        source_system, source_extract_ts, ingest_ts, business_event_ts,
        payload_hash, batch_id, load_id, pipeline_run_id
    from bronze
    -- Most recent extract wins per pharmacy claim.
    qualify row_number() over (
        partition by {{ variant_value('payload', 'pharmacy_claim_id', 'string') }}
        order by source_extract_ts desc, ingest_ts desc
    ) = 1

)

select
    t.pharmacy_claim_id,
    t.member_id,
    t.ndc,
    t.drug_name,
    t.days_supply,
    t.quantity_dispensed,
    t.fill_date,
    t.prescriber_npi,
    t.pharmacy_npi,
    t.charge_amount,
    t.allowed_amount,
    t.paid_amount,
    t.patient_pay_amount,

    {{ generate_surrogate_key(['t.pharmacy_claim_id']) }}             as pharmacy_claim_sk,
    true                                                              as is_current,
    coalesce(t.business_event_ts, t.fill_date::timestamp_ntz, current_timestamp()) as effective_from,
    cast(null as timestamp_ntz)                                      as effective_to,

    t.source_system,
    t.batch_id,
    t.load_id,
    t.pipeline_run_id,
    t.payload_hash,
    current_timestamp()                                              as created_at,
    current_timestamp()                                              as updated_at

from typed t
