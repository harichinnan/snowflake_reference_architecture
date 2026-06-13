-- =============================================================================
-- int_claim_adjustment_chain.sql
-- Layer: SILVER_CANONICAL (intermediate)
-- Grain: one row per (claim_id, claim_version).
--
-- Purpose
--   Claims mutate over their lifecycle through three mechanisms:
--     * adjustment  -- a corrected restatement (new claim_version, same claim_id,
--                      OR a new claim_id pointing back via original_claim_id).
--     * void        -- the claim is cancelled (void_indicator = true).
--     * reversal    -- a financial reversal/back-out (reversal_indicator = true).
--
--   This model reconstructs the chain so downstream logic can tell, for any
--   claim version, whether it supersedes (or is superseded by) another, and
--   classifies the lifecycle event type.
--
--   Linking:
--     - chain identity = coalesce(original_claim_id, claim_id): every version of
--       a logical claim shares one chain key. ORIGINAL rows seed the chain;
--       ADJUSTMENT / REVERSAL / VOID rows reference the originating claim via
--       original_claim_id.
--     - Within a chain: order by claim_version asc -> chain_seq 1..N (dense).
--
--   Normalized adjustment_type enum: 'ORIGINAL' | 'ADJUSTMENT' | 'REVERSAL' |
--   'VOID' (consumed by tests/assert_adjustment_chain_valid).
--
-- Materialized as a TABLE (full rebuild): chain resolution needs a global view
-- of all versions; incremental windows would risk breaking partial chains.
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags         = ['silver', 'canonical', 'claim', 'intermediate', 'adjustment_chain']
  )
}}

with claims as (

    select
        claim_id,
        claim_version,
        original_claim_id,
        adjustment_type            as raw_adjustment_type,
        void_indicator,
        reversal_indicator,
        adjustment_reason,
        claim_status,
        paid_amount,
        source_extract_ts,
        ingest_ts,
        business_event_ts
    from {{ ref('int_claim_event_deduped') }}

),

classified as (

    select
        c.*,

        -- ---- normalized lifecycle enum --------------------------------------
        -- Precedence: VOID > REVERSAL > ADJUSTMENT > ORIGINAL.
        case
            when coalesce(c.void_indicator, false)               then 'VOID'
            when coalesce(c.reversal_indicator, false)           then 'REVERSAL'
            when c.raw_adjustment_type is not null
              or c.original_claim_id is not null
              or coalesce(c.claim_version, 1) > 1                then 'ADJUSTMENT'
            else 'ORIGINAL'
        end                                                            as adjustment_type,

        coalesce(c.void_indicator, false)                              as is_void,
        coalesce(c.reversal_indicator, false)                          as is_reversal,

        -- The logical chain key shared by every version of a claim.
        coalesce(c.original_claim_id, c.claim_id)                      as chain_key

    from claims c

),

sequenced as (

    select
        cl.*,

        case when cl.adjustment_type in ('ADJUSTMENT', 'REVERSAL', 'VOID')
             then true else false end                                  as is_adjustment,

        -- Dense 1..N sequence within the logical chain, ordered by version.
        row_number() over (
            partition by cl.chain_key
            order by cl.claim_version asc, cl.source_extract_ts asc
        )                                                              as chain_seq,

        lag(cl.claim_version) over (
            partition by cl.chain_key
            order by cl.claim_version asc, cl.source_extract_ts asc
        )                                                              as prior_version_in_chain,

        case
            when cl.claim_version = max(cl.claim_version) over (partition by cl.chain_key)
                then true else false
        end                                                            as is_latest_version_in_chain

    from classified cl

)

select
    claim_id,
    claim_version,
    -- original_claim_id resolves to the chain head; ORIGINAL rows reference self
    -- so dangling-reference tests can validate against the claim universe.
    coalesce(original_claim_id, claim_id)                              as original_claim_id,
    adjustment_type,
    adjustment_reason,
    claim_status,
    paid_amount,
    is_void,
    is_reversal,
    is_adjustment,
    chain_seq,
    prior_version_in_chain,
    is_latest_version_in_chain,

    -- supersedes_claim_id: the claim this version replaces (NULL for the chain
    -- head / first version).
    case when prior_version_in_chain is not null
         then coalesce(original_claim_id, claim_id) end                as supersedes_claim_id,

    source_extract_ts,
    ingest_ts,
    business_event_ts

from sequenced
