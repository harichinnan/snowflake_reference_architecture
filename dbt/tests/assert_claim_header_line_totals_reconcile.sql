-- =============================================================================
-- singular test: assert_claim_header_line_totals_reconcile.sql
-- Target: silver_canonical.claim_header  vs  silver_canonical.claim_line
--
-- Business rule
--   For a given claim version, the HEADER paid_amount must equal the SUM of its
--   LINE paid_amounts. Header and lines come from the same conformed event, so
--   they must foot. We compare per (claim_id, claim_version) and allow a small
--   rounding tolerance (0.01) to absorb cent-level float noise.
--
--   We compare like-for-like versions so a header at version N is reconciled
--   against the lines at version N -- adjustments produce NEW versions, each of
--   which must internally reconcile. A claim with no lines at all (sum NULL) is
--   also a violation: a paying header with zero lines cannot be reconciled.
--
-- DCM domain: E (Data Quality) -- cross-table footing / reconciliation control.
--
-- Semantics: dbt SINGULAR test -- returns VIOLATING rows. Empty = PASS.
-- =============================================================================

with header as (

    select
        claim_id,
        claim_version,
        paid_amount                                       as header_paid_amount
    from {{ ref('claim_header') }}

),

line_totals as (

    select
        claim_id,
        claim_version,
        sum(paid_amount)                                  as lines_paid_amount,
        count(*)                                          as line_count
    from {{ ref('claim_line') }}
    group by claim_id, claim_version

)

select
    h.claim_id,
    h.claim_version,
    h.header_paid_amount,
    lt.lines_paid_amount,
    lt.line_count,
    h.header_paid_amount - coalesce(lt.lines_paid_amount, 0)
                                                          as reconciliation_diff
from header h
left join line_totals lt
       on h.claim_id      = lt.claim_id
      and h.claim_version = lt.claim_version
-- Violation when the header and summed lines differ beyond the rounding
-- tolerance, OR when a header has no lines to foot against at all.
where abs(h.header_paid_amount - coalesce(lt.lines_paid_amount, 0)) > 0.01
   or lt.claim_id is null
