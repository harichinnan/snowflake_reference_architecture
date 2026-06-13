-- =============================================================================
-- br_raw_adjudication_event.sql
-- BRONZE :: conformed adjudication / payment-decision events tied to a claim.
-- Reads BRONZE.BR_RAW_ADJUDICATION_EVENT, keeps the VARIANT payload, derives
-- the natural key (claim_id + adjudication_event_id), applies DCM record-status
-- rules, and dedupes idempotently.
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
        tags=['bronze', 'adjudication'],
        post_hook=[
            "{{ control_watermark_update(pipeline_name='bronze.br_raw_adjudication_event', watermark_column='business_event_ts', this_relation=this) }}"
        ]
    )
}}

with source_rows as (

    select *
    from {{ source('bronze', 'br_raw_adjudication_event') }}

    {% if is_incremental() %}
    where {{ incremental_watermark_filter(
                watermark_column='business_event_ts',
                pipeline_name='bronze.br_raw_adjudication_event'
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
        {{ variant_value('payload', 'claim_id') }}::string               as claim_id,
        {{ variant_value('payload', 'adjudication_event_id') }}::string  as adjudication_event_id,
        {{ variant_value('payload', 'adjudication_status') }}::string    as adjudication_status,
        {{ variant_value('payload', 'denial_reason_code') }}::string     as denial_reason_code,
        {{ variant_value('payload', 'allowed_amount') }}::number(18,2)   as allowed_amount,
        {{ variant_value('payload', 'paid_amount') }}::number(18,2)      as paid_amount,

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
        -- Natural key for an adjudication event = claim_id + adjudication_event_id.
        nullif(trim(claim_id), '') || '|' || nullif(trim(adjudication_event_id), '')
            as natural_key
    from typed

),

validated as (

    select
        *,
        -- DCM E quarantine rules for adjudication events:
        --   1. required keys present (claim_id, adjudication_event_id)
        --   2. future-dated business event
        --   3. negative paid amount on a non-adjustment/non-reversal event
        --   4. paid_amount exceeds allowed_amount (impossible payment)
        case
            when nullif(trim(claim_id), '') is null
                 or nullif(trim(adjudication_event_id), '') is null
                then 'MISSING_REQUIRED_KEY'
            when business_event_ts > current_timestamp()
                then 'FUTURE_DATED_EVENT'
            when paid_amount < 0
                 and lower(coalesce(event_type, '')) not in ('adjustment', 'reversal', 'void')
                then 'NEGATIVE_PAID_NON_ADJUSTMENT'
            when paid_amount is not null and allowed_amount is not null
                 and paid_amount > allowed_amount
                then 'PAID_EXCEEDS_ALLOWED'
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
        claim_id,
        adjudication_event_id,
        adjudication_status,
        denial_reason_code,
        allowed_amount,
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
        updated_at,

        -- DCM H: standardized audit/lineage columns.
        {{ audit_columns() }}
    from validated

    -- DCM D: idempotent dedupe on natural_key + payload_hash.
    qualify row_number() over (
        partition by natural_key, payload_hash
        order by source_extract_ts desc, ingest_ts desc
    ) = 1

)

select * from finalized
