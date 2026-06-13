-- =============================================================================
-- singular test: assert_no_duplicate_current_claims.sql
-- Target: silver_canonical.int_current_valid_claims
--
-- Business rule
--   The adjustment-chain resolution must leave EXACTLY ONE current version per
--   claim. int_current_valid_claims is the "which version is live now" model;
--   for every claim_id there must be at most one row with is_current = true.
--   More than one current row means the chain logic picked two winners, which
--   would double-count the claim's paid amount in every downstream gold model.
--
--   We count is_current = true rows per claim_id and fail any claim with > 1.
--
-- DCM domain: E (Data Quality) -- uniqueness / "single source of truth" control
--   over the current-version resolution (related to G Reprocessing lifecycle).
--
-- Semantics: dbt SINGULAR test -- returns VIOLATING claim_ids. Empty = PASS.
-- =============================================================================

select
    claim_id,
    count(*)                                              as current_row_count
from {{ ref('int_current_valid_claims') }}
where is_current = true
group by claim_id
having count(*) > 1
