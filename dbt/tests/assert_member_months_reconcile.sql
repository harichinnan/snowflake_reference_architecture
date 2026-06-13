-- =============================================================================
-- singular test: assert_member_months_reconcile.sql
-- Target: gold_member_months / silver_dimensional.fact_eligibility_month
--          vs  silver_canonical.eligibility_span  (source of truth)
--
-- Business rule
--   "Member months" is the coverage denominator behind every PMPM metric, so it
--   must tie back to the eligibility spans it is derived from. The authoritative
--   count is the number of DISTINCT (member_id, covered_month) the spans imply:
--   each span contributes one member-month for every calendar month it covers.
--
--   We expand eligibility_span to month grain, count distinct member-months, and
--   compare to the member-month count carried in gold_member_months. A mismatch
--   beyond a small tolerance means the dimensional/gold expansion gained or lost
--   coverage (off-by-one month boundaries, dropped open spans, double counting).
--
--   end_date NULL = still active -> capped at the current month so open coverage
--   is expanded through "today" exactly as the gold model should.
--
-- DCM domain: E (Data Quality) -- reconciliation of a certified denominator
--   (J Semantic) back to its canonical source.
--
-- Semantics: dbt SINGULAR test -- returns a single row ONLY when the totals do
--            not reconcile. Empty = PASS.
-- =============================================================================

{% set tolerance = 1 %}   {# allow a 1 member-month drift for boundary rounding #}

with span_months as (

    -- Expand each span into its covered months, then dedupe to distinct
    -- (member_id, covered_month). GENERATOR + month offset walks the span.
    select distinct
        s.member_id,
        dateadd(
            'month',
            seq.idx,
            date_trunc('month', s.start_date)
        )                                                 as covered_month
    from {{ ref('eligibility_span') }} s,
         lateral (
            select row_number() over (order by null) - 1 as idx
            from table(generator(rowcount => 600))       -- up to 50 yrs of months
         ) seq
    where dateadd('month', seq.idx, date_trunc('month', s.start_date))
              <= date_trunc('month', coalesce(s.end_date, current_date()))

),

expected as (

    select count(*) as expected_member_months
    from span_months

),

actual as (

    -- gold_member_months is one row per (member_id, coverage_month); its row
    -- count IS the member-month total. (Equivalently sum a member_month_count
    -- measure if the model pre-aggregates -- adjust if the grain differs.)
    select count(*) as actual_member_months
    from {{ ref('gold_member_months') }}

)

select
    e.expected_member_months,
    a.actual_member_months,
    a.actual_member_months - e.expected_member_months     as member_month_diff
from expected e
cross join actual a
where abs(a.actual_member_months - e.expected_member_months) > {{ tolerance }}
