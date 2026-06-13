-- =============================================================================
-- int_current_valid_claims.sql
-- Layer: SILVER_CANONICAL (intermediate)
-- Grain: one row per (claim_id, claim_version) with an is_current flag;
--        exactly one is_current = true per claim_id lineage.
--
-- Purpose
--   Resolve the *current effective state* of every claim. From the full deduped
--   version set + the adjustment chain we pick the single live version per
--   claim_id and mark everything else (older versions, voided, reversed,
--   superseded) as is_current = false.
--
--   Rules for the current effective version of a claim_id:
--     1. Discard versions that are voided or reversed -- they cannot be current.
--     2. Among the remaining (non-void / non-reversal) versions, the current one
--        is the highest claim_version (latest restatement), tie-broken by latest
--        source_extract_ts.
--     3. If EVERY version of a claim_id is voided/reversed, the claim has no
--        current state -> is_current = false for all (the claim is fully voided).
--
--   This is the gate the canonical entity models (claim_header / lines / dx /
--   procedures) read from, filtering to is_current = true.
-- =============================================================================

{{
  config(
    materialized   = 'incremental',
    incremental_strategy = 'merge',
    unique_key     = ['claim_id', 'claim_version'],
    on_schema_change = 'append_new_columns',
    tags           = ['silver', 'canonical', 'claim', 'intermediate', 'current_state']
  )
}}

with deduped as (

    select *
    from {{ ref('int_claim_event_deduped') }}

),

chain as (

    select
        claim_id,
        claim_version,
        is_void,
        is_reversal,
        is_adjustment,
        chain_seq,
        supersedes_claim_id,
        is_latest_version_in_chain
    from {{ ref('int_claim_adjustment_chain') }}

),

joined as (

    select
        d.*,
        c.is_void,
        c.is_reversal,
        c.is_adjustment,
        c.chain_seq,
        c.supersedes_claim_id,
        c.is_latest_version_in_chain
    from deduped d
    inner join chain c
        on  d.claim_id      = c.claim_id
        and d.claim_version = c.claim_version

),

ranked as (

    select
        j.*,

        -- A version is eligible to be "current" only if it is neither voided
        -- nor reversed.
        case when coalesce(j.is_void, false) = false
              and coalesce(j.is_reversal, false) = false
            then true else false
        end                                                            as is_eligible,

        -- Rank eligible versions within a claim_id; the #1 ranked eligible
        -- version is the current effective state.
        row_number() over (
            partition by j.claim_id
            order by
                case when coalesce(j.is_void, false) = false
                      and coalesce(j.is_reversal, false) = false
                     then 0 else 1 end asc,           -- eligible first
                j.claim_version desc,                 -- latest restatement
                j.source_extract_ts desc              -- physical recency tiebreak
        )                                                              as current_rank

    from joined j

)

select
    r.* exclude (current_rank, is_eligible),

    -- is_current: the top-ranked *eligible* version is the live one. If the
    -- top-ranked row is itself ineligible (all versions void/reversed) then no
    -- row in the lineage is current.
    case
        when r.current_rank = 1 and r.is_eligible then true
        else false
    end                                                                as is_current,

    -- Effective dating for SCD-style consumption downstream.
    r.business_event_ts                                                as effective_from_ts

from ranked r
