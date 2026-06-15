-- =============================================================================
-- br_raw_pharmacy_event.sql
-- BRONZE :: conformed pharmacy (Rx) claim events. Reads
-- BRONZE.BR_RAW_PHARMACY_EVENT, keeps the VARIANT payload, derives the natural
-- key (pharmacy_claim_id), applies DCM record-status rules, and dedupes.
--
-- DCM domains: A (Source), B (Batch), C (Watermark), D (Idempotency),
--              E (Data Quality).
-- =============================================================================

{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key='bronze_event_id',
        on_schema_change='sync_all_columns',
        tags=['bronze', 'pharmacy'],
        post_hook=[
            "{{ control_watermark_update(pipeline_name='bronze.br_raw_pharmacy_event', watermark_column='business_event_ts', this_relation=this) }}"
        ]
    )
}}

with source_rows as (

    select *
    from {{ source('bronze_landing', 'br_raw_pharmacy_event') }}

    {% if is_incremental() %}
    where {{ incremental_watermark_filter(
                watermark_column='business_event_ts',
                pipeline_name='bronze.br_raw_pharmacy_event'
            ) }}
    {% endif %}

),

typed as (

    select
        bronze_event_id,
        source_system,
        source_file_name,
        source_file_row_number,
        source_extract_ts,
        ingest_ts,
        event_type,
        business_event_ts,
        payload,

        coalesce(payload_hash, {{ claim_payload_hash('payload') }}) as payload_hash,

        -- business fields from the VARIANT.
        {{ variant_value('payload', 'pharmacy_claim_id') }}::string  as pharmacy_claim_id,
        {{ variant_value('payload', 'member_id') }}::string          as member_id,
        {{ variant_value('payload', 'ndc') }}::string                as ndc,
        try_to_date({{ variant_value('payload', 'fill_date') }}::string) as fill_date,
        {{ variant_value('payload', 'days_supply') }}::number         as days_supply,
        {{ variant_value('payload', 'paid_amount') }}::number(18,2)   as paid_amount,

        batch_id,
        load_id,
        pipeline_run_id,
        coalesce(is_reprocessed, false) as is_reprocessed,
        record_status as record_status_in,
        quarantine_reason as quarantine_reason_in,
        created_at,
        updated_at
    from source_rows

),

keyed as (

    select
        *,
        -- Natural key for a pharmacy claim = pharmacy_claim_id.
        nullif(trim(pharmacy_claim_id), '') as natural_key
    from typed

),

validated as (

    select
        *,
        -- DCM E quarantine rules for pharmacy events:
        --   1. required keys present (pharmacy_claim_id, member_id)
        --   2. future-dated fill / business event
        --   3. negative paid amount on a non-adjustment/non-reversal event
        --   4. non-positive days_supply when supplied
        case
            when nullif(trim(pharmacy_claim_id), '') is null
                 or nullif(trim(member_id), '') is null
                then 'MISSING_REQUIRED_KEY'
            when fill_date > current_date()
                 or business_event_ts > current_timestamp()
                then 'FUTURE_DATED_EVENT'
            when paid_amount < 0
                 and lower(coalesce(event_type, '')) not in ('adjustment', 'reversal', 'void')
                then 'NEGATIVE_PAID_NON_ADJUSTMENT'
            when days_supply is not null and days_supply <= 0
                then 'INVALID_DAYS_SUPPLY'
            else null
        end as derived_quarantine_reason
    from keyed

),

finalized as (

    select
        bronze_event_id,
        source_system,
        source_file_name,
        source_file_row_number,
        source_extract_ts,
        ingest_ts,
        event_type,
        business_event_ts,
        natural_key,
        pharmacy_claim_id,
        member_id,
        ndc,
        fill_date,
        days_supply,
        paid_amount,
        payload,
        payload_hash,

        case
            when derived_quarantine_reason is not null then 'QUARANTINE'
            when record_status_in = 'QUARANTINE'       then 'QUARANTINE'
            else 'VALID'
        end as record_status,
        coalesce(derived_quarantine_reason, quarantine_reason_in) as quarantine_reason,

        batch_id,
        load_id,
        pipeline_run_id,
        is_reprocessed,
        created_at,
        updated_at
    from validated

    -- DCM D: idempotent dedupe on natural_key + payload_hash.
    qualify row_number() over (
        partition by natural_key, payload_hash
        order by source_extract_ts desc, ingest_ts desc
    ) = 1

)

select * from finalized
