-- =============================================================================
-- br_raw_provider_event.sql
-- BRONZE :: conformed provider master events. Reads
-- BRONZE.BR_RAW_PROVIDER_EVENT, keeps the VARIANT payload, derives the natural
-- key (npi), applies DCM record-status rules (NPI must be a present 10-digit
-- identifier), and dedupes idempotently.
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
        tags=['bronze', 'provider'],
        post_hook=[
            "{{ control_watermark_update(pipeline_name='bronze.br_raw_provider_event', watermark_column='business_event_ts', this_relation=this) }}"
        ]
    )
}}

with source_rows as (

    select *
    from {{ source('bronze', 'br_raw_provider_event') }}

    {% if is_incremental() %}
    where {{ incremental_watermark_filter(
                watermark_column='business_event_ts',
                pipeline_name='bronze.br_raw_provider_event'
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
        {{ variant_value('payload', 'npi') }}::string             as npi,
        {{ variant_value('payload', 'provider_name') }}::string   as provider_name,
        {{ variant_value('payload', 'provider_type') }}::string   as provider_type,
        {{ variant_value('payload', 'taxonomy_code') }}::string   as taxonomy_code,

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
        -- Natural key for a provider = npi.
        nullif(trim(npi), '') as natural_key
    from typed

),

validated as (

    select
        *,
        -- DCM E quarantine rules for provider events:
        --   1. NPI present
        --   2. NPI is a 10-digit numeric (basic NPI shape check)
        --   3. future-dated business event
        case
            when nullif(trim(npi), '') is null
                then 'MISSING_REQUIRED_KEY'
            when not regexp_like(trim(npi), '^[0-9]{10}$')
                then 'INVALID_NPI_FORMAT'
            when business_event_ts > current_timestamp()
                then 'FUTURE_DATED_EVENT'
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
        npi,
        provider_name,
        provider_type,
        taxonomy_code,
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
