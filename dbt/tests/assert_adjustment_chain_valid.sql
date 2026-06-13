-- =============================================================================
-- singular test: assert_adjustment_chain_valid.sql
-- Target: silver_canonical.int_claim_adjustment_chain
--
-- Business rule
--   An adjustment chain must be structurally sound. We enforce three invariants
--   and return any row that breaks one (with a violation_reason so the failure
--   is self-describing):
--
--     1. DANGLING ORIGINAL -- an ADJUSTMENT / REVERSAL / VOID event references an
--        original_claim_id that does not exist as a claim in the chain. The
--        adjustment points at a parent that was never ingested.
--
--     2. REVERSAL WITHOUT PRIOR PAID -- a REVERSAL must back out money that was
--        actually paid; there must be a PRIOR version in the same chain whose
--        cumulative paid amount was > 0. A reversal of nothing is invalid.
--
--     3. BROKEN VERSION ORDER -- chain_seq must be a strict, gap-free 1..N
--        sequence ordered by claim_version. A duplicated or out-of-order seq
--        means the chain was assembled incorrectly.
--
-- DCM domain: G (Reprocessing / adjustment lifecycle) + E (Data Quality
--   referential & ordering integrity).
--
-- Semantics: dbt SINGULAR test -- returns VIOLATING rows. Empty = PASS.
-- =============================================================================

with chain as (

    select
        original_claim_id,
        claim_id,
        claim_version,
        adjustment_type,                 -- 'ORIGINAL' | 'ADJUSTMENT' | 'REVERSAL' | 'VOID'
        paid_amount,
        chain_seq
    from {{ ref('int_claim_adjustment_chain') }}

),

-- Set of claim_ids that actually exist (the universe an original_claim_id must
-- resolve to). An ORIGINAL's own claim_id is the head of its chain.
existing_claims as (

    select distinct claim_id
    from chain

),

-- Running paid prior to each row, within its chain, to validate reversals.
with_prior as (

    select
        c.*,
        coalesce(
            sum(c.paid_amount) over (
                partition by c.original_claim_id
                order by c.claim_version
                rows between unbounded preceding and 1 preceding
            ), 0)                                          as prior_cumulative_paid,
        -- Expected dense 1..N order by version within the chain.
        row_number() over (
            partition by c.original_claim_id
            order by c.claim_version
        )                                                  as expected_seq
    from chain c

),

violations as (

    -- (1) Dangling original reference: a non-original event whose parent claim
    --     is not present in the chain universe.
    select
        c.original_claim_id,
        c.claim_id,
        c.claim_version,
        c.adjustment_type,
        'DANGLING_ORIGINAL'                               as violation_reason
    from with_prior c
    where c.adjustment_type <> 'ORIGINAL'
      and c.original_claim_id not in (select claim_id from existing_claims)

    union all

    -- (2) Reversal with no prior paid amount to back out.
    select
        c.original_claim_id,
        c.claim_id,
        c.claim_version,
        c.adjustment_type,
        'REVERSAL_WITHOUT_PRIOR_PAID'                     as violation_reason
    from with_prior c
    where c.adjustment_type = 'REVERSAL'
      and c.prior_cumulative_paid <= 0

    union all

    -- (3) Version ordering broken: stored chain_seq disagrees with the dense
    --     version-ordered sequence (gap, duplicate, or out-of-order).
    select
        c.original_claim_id,
        c.claim_id,
        c.claim_version,
        c.adjustment_type,
        'BROKEN_VERSION_ORDER'                            as violation_reason
    from with_prior c
    where c.chain_seq <> c.expected_seq

)

select *
from violations
