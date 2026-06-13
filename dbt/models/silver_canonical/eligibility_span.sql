-- =============================================================================
-- eligibility_span.sql
-- Layer: SILVER_CANONICAL (canonical entity)
-- Grain: one row per non-overlapping coverage span (member_id, plan_id, span).
--
-- Purpose
--   Reconstruct continuous, NON-OVERLAPPING coverage spans per member + plan
--   from discrete eligibility events. Source events can:
--     * overlap (a renewal sent before the prior term ends),
--     * be retroactive (retro_active_indicator = true with a retro_effective_date
--       that moves coverage_start earlier than originally stated),
--     * be open-ended (NULL coverage_end_date = still active).
--
--   Approach (classic "sessionization" / interval merge):
--     1. Normalize each event: apply retro_effective_date to the start when
--        retroactive; coalesce open end dates to a far-future sentinel.
--     2. Order events per (member_id, plan_id) and detect the start of a new
--        span whenever the current start is after the running max end-so-far
--        of all prior events (a true gap). Otherwise events belong to the same
--        merged span.
--     3. Collapse each merged group to MIN(start) / MAX(end).
--
-- Keys
--   eligibility_sk -- surrogate over (member_id, plan_id, span_start).
-- =============================================================================

{{
  config(
    materialized   = 'incremental',
    incremental_strategy = 'merge',
    unique_key     = 'eligibility_sk',
    on_schema_change = 'append_new_columns',
    tags           = ['silver', 'canonical', 'entity', 'eligibility']
  )
}}

{# Sentinel for open-ended (still-active) coverage. #}
{% set open_end_sentinel = "to_date('9999-12-31')" %}

with events as (

    select
        {{ variant_value('payload', 'member_id', 'string') }}            as member_id,
        {{ variant_value('payload', 'payer_id', 'string') }}            as payer_id,
        {{ variant_value('payload', 'plan_id', 'string') }}            as plan_id,
        {{ variant_value('payload', 'plan_type', 'string') }}          as plan_type,
        {{ variant_value('payload', 'eligibility_status', 'string') }} as eligibility_status,
        {{ variant_value('payload', 'coverage_start_date', 'date') }}  as coverage_start_date,
        {{ variant_value('payload', 'coverage_end_date', 'date') }}    as coverage_end_date,
        {{ variant_value('payload', 'retro_active_indicator', 'boolean') }} as retro_active_indicator,
        {{ variant_value('payload', 'retro_effective_date', 'date') }} as retro_effective_date,
        source_system,
        source_extract_ts,
        ingest_ts,
        business_event_ts,
        payload_hash,
        batch_id,
        load_id,
        pipeline_run_id
    from {{ ref('br_raw_eligibility_event') }}
    where record_status = 'VALID'

),

-- 1. Apply retroactivity and open-end normalization.
normalized as (

    select
        member_id,
        payer_id,
        plan_id,
        plan_type,
        eligibility_status,

        -- Retroactive eligibility moves the start earlier: use the earlier of
        -- the stated start and the retro_effective_date.
        case
            when coalesce(retro_active_indicator, false) and retro_effective_date is not null
                then least(coverage_start_date, retro_effective_date)
            else coverage_start_date
        end                                                            as span_start,

        -- Open-ended coverage -> sentinel far-future end for interval math.
        coalesce(coverage_end_date, {{ open_end_sentinel }})           as span_end,
        coverage_end_date                                              as raw_coverage_end_date,
        coalesce(retro_active_indicator, false)                        as retro_active_indicator,

        source_system,
        source_extract_ts,
        ingest_ts,
        business_event_ts,
        payload_hash,
        batch_id,
        load_id,
        pipeline_run_id
    from events
    where coverage_start_date is not null or retro_effective_date is not null

),

-- 2. Detect span boundaries: a new span starts when this event's start is
--    strictly after the running max end of all prior events in the partition.
ordered as (

    select
        n.*,
        -- Max end among strictly-prior events in the ordered window.
        max(span_end) over (
            partition by member_id, plan_id
            order by span_start, span_end
            rows between unbounded preceding and 1 preceding
        )                                                              as prior_max_end
    from normalized n

),

flagged as (

    select
        o.*,
        -- New span when there's a real gap (start after prior coverage ended).
        -- First row in partition (prior_max_end null) is always a new span.
        case
            when prior_max_end is null then 1
            when span_start > prior_max_end then 1
            else 0
        end                                                            as is_new_span
    from ordered o

),

-- Running sum of new-span flags = a stable group id per merged span.
grouped as (

    select
        f.*,
        sum(is_new_span) over (
            partition by member_id, plan_id
            order by span_start, span_end
            rows between unbounded preceding and current row
        )                                                              as span_group
    from flagged f

),

-- 3. Collapse each merged group.
collapsed as (

    select
        member_id,
        plan_id,
        span_group,
        max(payer_id)                                                  as payer_id,
        max(plan_type)                                                 as plan_type,
        -- Status of the latest contributing event in the span.
        max_by(eligibility_status, business_event_ts)                  as eligibility_status,
        bool_or(retro_active_indicator)                                as retro_active_indicator,
        min(span_start)                                                as coverage_start_date,
        max(span_end)                                                  as span_end_internal,
        -- Translate the sentinel back to NULL = open-ended coverage.
        case when max(span_end) = {{ open_end_sentinel }} then null
             else max(span_end) end                                    as coverage_end_date,
        max(business_event_ts)                                         as business_event_ts,
        max_by(source_system, source_extract_ts)                       as source_system,
        max_by(batch_id, source_extract_ts)                            as batch_id,
        max_by(load_id, source_extract_ts)                             as load_id,
        max_by(pipeline_run_id, source_extract_ts)                     as pipeline_run_id,
        max_by(payload_hash, source_extract_ts)                        as payload_hash
    from grouped
    group by member_id, plan_id, span_group

)

select
    member_id,
    payer_id,
    plan_id,
    plan_type,
    eligibility_status,
    coverage_start_date,
    coverage_end_date,
    -- Generic span aliases consumed by tests/assert_eligibility_spans_do_not_overlap.
    coverage_start_date                                               as start_date,
    coverage_end_date                                                 as end_date,
    retro_active_indicator,

    -- ---- surrogate + audit --------------------------------------------------
    {{ generate_surrogate_key(['member_id', 'plan_id', 'coverage_start_date']) }} as eligibility_sk,
    -- span_id alias (= eligibility_sk) referenced by the overlap test.
    {{ generate_surrogate_key(['member_id', 'plan_id', 'coverage_start_date']) }} as span_id,

    -- A span is current when its coverage is open-ended or ends in the future.
    case when coverage_end_date is null or coverage_end_date >= current_date()
         then true else false end                                      as is_current,
    coverage_start_date                                                as effective_from,
    coverage_end_date                                                  as effective_to,

    source_system,
    batch_id,
    load_id,
    pipeline_run_id,
    payload_hash,
    current_timestamp()                                               as created_at,
    current_timestamp()                                               as updated_at

from collapsed
