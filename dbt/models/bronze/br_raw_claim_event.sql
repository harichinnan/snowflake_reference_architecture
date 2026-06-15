-- =============================================================================
-- br_raw_claim_event.sql
-- BRONZE :: conformed claim lifecycle events (header/line, adjustment, void,
-- reversal). Reads the BRONZE.BR_RAW_CLAIM_EVENT landing table, keeps the
-- immutable VARIANT payload, derives hash keys + natural key, applies DCM
-- record-status (VALID / QUARANTINE) rules, and dedupes idempotently.
--
-- DCM domains exercised here:
--   A (Source)        -- source_system / source_file_* carried through
--   B (Batch)         -- batch_id / load_id / pipeline_run_id carried through
--   C (Watermark)     -- incremental_watermark_filter + apply_lookback_window
--   D (Idempotency)   -- payload_hash + QUALIFY dedupe + MERGE on bronze_event_id
--   E (Data Quality)  -- record_status flagging of malformed rows
-- =============================================================================

{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key='bronze_event_id',
        on_schema_change='sync_all_columns',
        tags=['bronze', 'claim'],
        post_hook=[
            "{{ control_watermark_update(pipeline_name='bronze.br_raw_claim_event', watermark_column='business_event_ts', this_relation=this) }}"
        ]
    )
}}

with source_rows as (

    select *
    from {{ source('bronze_landing', 'br_raw_claim_event') }}

    {% if is_incremental() %}
    -- DCM C: only pull rows at/after the stored watermark minus the configured
    -- lookback window, so late-arriving claims that touch already-loaded periods
    -- are re-evaluated. The macro reads CONTROL.PIPELINE_CONFIG / WATERMARK_STATE.
    where {{ incremental_watermark_filter(
                watermark_column='business_event_ts',
                pipeline_name='bronze.br_raw_claim_event'
            ) }}
    {% endif %}

),

typed as (

    select
        -- identity / DCM keys ----------------------------------------------
        bronze_event_id,
        source_system,
        source_file_name,
        source_file_row_number,
        source_extract_ts,
        ingest_ts,
        event_type,
        business_event_ts,

        -- payload (kept as immutable VARIANT) ------------------------------
        payload,

        -- DCM D: ensure a payload_hash exists; compute deterministically if the
        -- landing load did not supply one. claim_payload_hash hashes the
        -- canonical business content of the VARIANT payload.
        coalesce(payload_hash, {{ claim_payload_hash('payload') }}) as payload_hash,

        -- business fields extracted from the VARIANT for keying / validation.
        {{ variant_value('payload', 'claim_id') }}::string         as claim_id,
        {{ variant_value('payload', 'claim_version') }}::number     as claim_version,
        {{ variant_value('payload', 'member_id') }}::string         as member_id,
        try_to_date({{ variant_value('payload', 'service_from') }}::string) as service_from_date,
        try_to_date({{ variant_value('payload', 'service_to') }}::string)   as service_to_date,
        {{ variant_value('payload', 'paid_amount') }}::number(18,2)  as paid_amount,

        -- DCM B: data-control-model columns carried straight through.
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
        -- Natural key for a claim event = claim_id + claim_version.
        nullif(trim(claim_id), '') || '|' || coalesce(claim_version::string, '0')
            as natural_key
    from typed

),

validated as (

    select
        *,
        -- DCM E: derive a single quarantine_reason describing the FIRST failing
        -- rule (null when the row is clean). Checks, in order:
        --   1. required business keys present (claim_id, member_id)
        --   2. impossible date span (service_to < service_from)
        --   3. future-dated service / business event
        --   4. negative paid amount on a non-adjustment/non-reversal event
        case
            when nullif(trim(claim_id), '') is null
                 or nullif(trim(member_id), '') is null
                then 'MISSING_REQUIRED_KEY'
            when service_to_date is not null
                 and service_from_date is not null
                 and service_to_date < service_from_date
                then 'IMPOSSIBLE_DATE_SPAN'
            when service_from_date > current_date()
                 or business_event_ts > current_timestamp()
                then 'FUTURE_DATED_EVENT'
            when paid_amount < 0
                 and lower(coalesce(event_type, '')) not in ('adjustment', 'reversal', 'void')
                then 'NEGATIVE_PAID_NON_ADJUSTMENT'
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
        claim_version,
        member_id,
        service_from_date,
        service_to_date,
        paid_amount,
        payload,
        payload_hash,

        -- DCM E: VALID unless a rule fired; preserve any upstream QUARANTINE.
        case
            when derived_quarantine_reason is not null then 'QUARANTINE'
            when record_status_in = 'QUARANTINE'       then 'QUARANTINE'
            else 'VALID'
        end as record_status,
        coalesce(derived_quarantine_reason, quarantine_reason_in) as quarantine_reason,

        -- DCM B columns
        batch_id,
        load_id,
        pipeline_run_id,
        is_reprocessed,
        created_at,
        updated_at
    from validated

    -- DCM D: idempotent dedupe. Within a natural_key + payload_hash we keep the
    -- freshest source extract / ingest so re-delivered identical payloads and
    -- lookback re-reads collapse to one row.
    qualify row_number() over (
        partition by natural_key, payload_hash
        order by source_extract_ts desc, ingest_ts desc
    ) = 1

)

select * from finalized
