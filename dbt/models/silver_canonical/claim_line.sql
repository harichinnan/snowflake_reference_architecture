-- =============================================================================
-- claim_line.sql
-- Layer: SILVER_CANONICAL (canonical entity)
-- Grain: one row per claim service line (claim_id, line_number).
--
-- Purpose
--   Explode the payload:lines[] array of each CURRENT VALID claim into a flat
--   line-level table. Each line carries its own procedure/revenue/POS, service
--   date, units and money. Lines roll up to the header via claim_header_sk.
--
-- Keys
--   claim_line_id    -- source natural key for the line.
--   claim_line_sk    -- surrogate over (claim_id, claim_version, line_number).
--   claim_header_sk  -- FK to claim_header (surrogate over claim_id+version).
-- =============================================================================

{{
  config(
    materialized   = 'incremental',
    incremental_strategy = 'merge',
    unique_key     = 'claim_line_sk',
    on_schema_change = 'append_new_columns',
    tags           = ['silver', 'canonical', 'entity', 'claim', 'line']
  )
}}

with current_claims as (

    select
        claim_id,
        claim_version,
        lines_raw,
        source_system,
        batch_id,
        load_id,
        pipeline_run_id,
        payload_hash,
        business_event_ts,
        is_current,
        ingest_ts
    from {{ ref('int_current_valid_claims') }}
    where is_current = true

    {% if is_incremental() %}
      and {{ incremental_watermark_filter('ingest_ts') }}
    {% endif %}

),

-- LATERAL FLATTEN the lines array. outer => true so claims with no lines still
-- pass through (line fields NULL) -- but we filter empties out below.
flattened as (

    select
        c.claim_id,
        c.claim_version,
        l.value                                                        as line,
        c.source_system,
        c.batch_id,
        c.load_id,
        c.pipeline_run_id,
        c.payload_hash,
        c.business_event_ts,
        c.is_current
    from current_claims c,
         lateral flatten(input => c.lines_raw, outer => false) l

),

typed as (

    select
        -- ---- line attributes (typed out of the line VARIANT) -------------
        {{ variant_value('line', 'claim_line_id', 'string') }}         as claim_line_id,
        f.claim_id,
        f.claim_version,
        {{ variant_value('line', 'line_number', 'number') }}           as line_number,
        {{ variant_value('line', 'procedure_code', 'string') }}        as procedure_code,
        {{ variant_value('line', 'revenue_code', 'string') }}          as revenue_code,
        {{ variant_value('line', 'place_of_service', 'string') }}      as place_of_service,
        {{ variant_value('line', 'service_date', 'date') }}            as service_date,
        {{ variant_value('line', 'units', 'number') }}                 as units,
        {{ variant_value('line', 'charge_amount', 'number') }}         as charge_amount,
        {{ variant_value('line', 'allowed_amount', 'number') }}        as allowed_amount,
        {{ variant_value('line', 'paid_amount', 'number') }}           as paid_amount,
        f.source_system,
        f.batch_id,
        f.load_id,
        f.pipeline_run_id,
        f.payload_hash,
        f.business_event_ts,
        f.is_current
    from flattened f

)

select
    t.claim_line_id,
    t.claim_id,
    t.claim_version,
    t.line_number,
    t.procedure_code,
    t.revenue_code,
    t.place_of_service,
    t.service_date,
    t.units,
    t.charge_amount,
    t.allowed_amount,
    t.paid_amount,

    -- ---- surrogate + FK + audit ------------------------------------------
    {{ generate_surrogate_key(['t.claim_id', 't.claim_version', 't.line_number']) }} as claim_line_sk,
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
