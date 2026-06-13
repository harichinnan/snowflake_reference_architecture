-- =============================================================================
-- singular test: assert_eligibility_spans_do_not_overlap.sql
-- Target: silver_canonical.eligibility_span
--
-- Business rule
--   A member can hold at most one active coverage span PER PLAN at any instant.
--   Two spans for the same (member_id, plan_id) must NOT overlap in time. If
--   they do, member-month and eligibility-derived denominators double-count
--   coverage, inflating PMPM and utilization-per-member metrics.
--
--   Overlap test (half-open intervals [start, end)):
--       a.start < b.end  AND  a.end > b.start
--   We guard against matching a row to itself by ordering on a stable key
--   (span_id) so each overlapping PAIR is reported once, not twice.
--
--   NULL end_date is treated as "open / still active" -> coalesced to a far
--   future date so an open span overlaps anything that starts after it.
--
-- DCM domain: E (Data Quality) -- temporal integrity / non-overlap constraint.
--
-- Semantics: dbt SINGULAR test -- returns VIOLATING (overlapping) pairs.
--            Empty = PASS.
-- =============================================================================

with spans as (

    select
        span_id,
        member_id,
        plan_id,
        start_date,
        coalesce(end_date, date '9999-12-31')             as end_date
    from {{ ref('eligibility_span') }}

)

select
    a.member_id,
    a.plan_id,
    a.span_id                                             as span_id_a,
    a.start_date                                          as start_date_a,
    a.end_date                                            as end_date_a,
    b.span_id                                             as span_id_b,
    b.start_date                                          as start_date_b,
    b.end_date                                            as end_date_b
from spans a
join spans b
  on a.member_id = b.member_id
 and a.plan_id   = b.plan_id
 and a.span_id   < b.span_id            -- distinct rows; report each pair once
-- Half-open interval overlap.
where a.start_date < b.end_date
  and a.end_date   > b.start_date
