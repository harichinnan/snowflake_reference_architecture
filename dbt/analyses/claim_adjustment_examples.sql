-- =============================================================================
-- analysis: claim_adjustment_examples.sql
-- Layer: SILVER (read-only analysis -- compiled, not materialized)
--
-- Purpose
--   Walk a claim's adjustment lifecycle end to end. int_claim_adjustment_chain
--   resolves each claim version into an ordered chain (original ->
--   adjustment(s) -> reversal / void) and marks which version is_current.
--   fact_claim_adjustment carries the per-event paid deltas. These queries show
--   how to read a chain and reconcile the running paid amount.
--
-- DCM domains: A (Source -- original_claim_id linkage), G (Reprocessing /
--   adjustment lifecycle). The "current valid claim" resolution feeds gold.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Full chain for a single original claim, in version order. Shows the
--    original, every adjustment, and any reversal/void, with the per-version
--    paid_amount and the lifecycle indicators.
--    Swap the literal claim id for the chain you want to inspect.
-- -----------------------------------------------------------------------------
select
    chain.original_claim_id,
    chain.claim_id,
    chain.claim_version,
    chain.adjustment_type,                 -- 'ORIGINAL' | 'ADJUSTMENT' | 'REVERSAL' | 'VOID'
    chain.void_indicator,
    chain.reversal_indicator,
    chain.paid_amount,
    chain.is_current,
    chain.chain_seq                        -- 1-based position within the chain
from {{ ref('int_claim_adjustment_chain') }} chain
where chain.original_claim_id = 'CLM-ORIGINAL-0001'   -- <-- choose a chain
order by chain.chain_seq
;

-- -----------------------------------------------------------------------------
-- 2. Per-event paid delta walk. fact_claim_adjustment records the signed change
--    each event applied to the paid amount; the running total should land on the
--    current version's paid_amount once the whole chain is summed.
-- -----------------------------------------------------------------------------
select
    adj.original_claim_id,
    adj.claim_id,
    adj.claim_version,
    adj.adjustment_type,
    adj.prior_paid_amount,
    adj.paid_amount,
    adj.paid_delta_amount,                 -- paid_amount - prior_paid_amount
    sum(adj.paid_delta_amount) over (
        partition by adj.original_claim_id
        order by adj.claim_version
        rows between unbounded preceding and current row
    )                                      as running_paid_amount
from {{ ref('fact_claim_adjustment') }} adj
where adj.original_claim_id = 'CLM-ORIGINAL-0001'    -- <-- choose a chain
order by adj.claim_version
;

-- -----------------------------------------------------------------------------
-- 3. Reversal / void summary -- chains that ended in a reversal or void net the
--    paid amount back toward zero. Surfaces chains whose final current version
--    is a reversal/void so finance can confirm the money was fully backed out.
-- -----------------------------------------------------------------------------
select
    chain.original_claim_id,
    count(*)                                              as chain_length,
    max(chain.chain_seq)                                  as last_seq,
    max_by(chain.adjustment_type, chain.chain_seq)        as final_event_type,
    max_by(chain.paid_amount, chain.chain_seq)            as final_paid_amount
from {{ ref('int_claim_adjustment_chain') }} chain
group by chain.original_claim_id
having max_by(chain.adjustment_type, chain.chain_seq) in ('REVERSAL', 'VOID')
order by chain.original_claim_id
;
