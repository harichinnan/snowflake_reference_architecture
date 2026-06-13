-- =============================================================================
-- br_raw_eligibility_event.sql
-- BRONZE :: conformed member eligibility / coverage-span events. Reads
-- BRONZE.BR_RAW_ELIGIBILITY_EVENT, keeps the VARIANT payload, derives the
-- natural key (member_id + coverage_start_date + plan_id), normalizes the
-- retro-active indicator, applies DCM record-status rules, and dedupes.
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
        tags=['bronze', 'eligibility'],
        post_hook=[
            "{{ control_watermark_update(pipeline_name='bronze.br_raw_eligibility_event', watermark_column='business_event_ts', this_relation=this) }}"
        ]
    )
}}

with source_rows as (

    select *
    from {{ source('bronze', 'br_raw_eligibility_event') }}

    {% if is_incremental() %}
    where {{ incremental_watermark_filter(
                watermark_column='business_event_ts',
                pipeline_name='bronze.br_raw_eligibility_event'
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

        -- DCM D: deterministic payload hash if the landing load omitted one.
        coalesce(payload_hash, {{ claim_payload_hash('payload') }}) as payload_hash,

        -- business fields from the VARIANT.
        {{ variant_value('payload', 'member_id') }}::string                 as member_id,
        {{ variant_value('payload', 'plan_id') }}::string                   as plan_id,
        try_to_date({{ variant_value('payload', 'coverage_start_date') }}::string) as coverage_start_date,
        try_to_date({{ variant_value('payload', 'coverage_end_date') }}::string)   as coverage_end_date,
        -- Retro-active coverage handling: normalize the indicator to a boolean.
        coalesce(
            try_to_boolean({{ variant_value('payload', 'retro_active_indicator') }}::string),
            lower({{ variant_value('payload', 'retro_active_indicator') }}::string) in ('y', 'yes', 'true', '1'),
            false
        ) as retro_active_indicator,

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
        -- Natural key = member_id + coverage_start_date + plan_id.
        nullif(trim(member_id), '') || '|'
            || coalesce(coverage_start_date::string, 'NA') || '|'
            || coalesce(nullif(trim(plan_id), ''), 'NA') as natural_key
    from typed

),

validated as (

    select
        *,
        -- DCM E quarantine rules for eligibility spans:
        --   1. required keys present (member_id, plan_id, coverage_start_date)
        --   2. impossible span (coverage_end_date < coverage_start_date)
        --   3. future-dated coverage start (retro-active spans are allowed to
        --      start in the past, but never in the future)
        case
            when nullif(trim(member_id), '') is null
                 or nullif(trim(plan_id), '') is null
                 or coverage_start_date is null
                then 'MISSING_REQUIRED_KEY'
            when coverage_end_date is not null
                 and coverage_end_date < coverage_start_date
                then 'IMPOSSIBLE_COVERAGE_SPAN'
            when coverage_start_date > current_date()
                 or business_event_ts > current_timestamp()
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
        member_id,
        plan_id,
        coverage_start_date,
        coverage_end_date,
        retro_active_indicator,
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
