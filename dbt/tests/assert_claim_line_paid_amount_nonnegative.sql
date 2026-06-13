-- =============================================================================
-- singular test: assert_claim_line_paid_amount_nonnegative.sql
-- Target: silver_dimensional.fact_claim_line
--
-- Business rule
--   A paid claim line cannot pay out a NEGATIVE amount on the happy path. The
--   ONLY legitimate way paid_amount goes negative is a lifecycle event that
--   claws money back -- an adjustment or a reversal. Those lines are explicitly
--   flagged (adjustment_flag / reversal_flag) and are expected to carry negative
--   deltas, so we exclude them.
--
--   A negative paid_amount on a plain, non-adjustment / non-reversal line is a
--   data-quality defect (bad sign, mis-mapped credit, corrupt source).
--
-- DCM domain: E (Data Quality) -- value-range / sign integrity assertion.
--
-- Semantics: this is a dbt SINGULAR test -- it returns the VIOLATING rows.
--            Empty result set = PASS.
-- =============================================================================

select
    claim_line_id,
    claim_id,
    claim_line_number,
    paid_amount,
    adjustment_flag,
    reversal_flag
from {{ ref('fact_claim_line') }}
where paid_amount < 0
  -- Negative is allowed only when this line is a clawback (adjustment/reversal).
  and not (coalesce(adjustment_flag, false) or coalesce(reversal_flag, false))
