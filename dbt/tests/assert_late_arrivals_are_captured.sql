-- =============================================================================
-- singular test: assert_late_arrivals_are_captured.sql
-- Target: silver_canonical.int_late_arriving_claims  ->  claim_header / fact_claim_line
--
-- Business rule
--   Late-arriving claims must NOT be silently dropped. Every claim flagged as
--   late-arriving (int_late_arriving_claims.late_arrival_flag = true) is a real,
--   VALID claim version that simply landed after its service period closed -- it
--   still has to flow through to the conformed claim_header and into the line
--   fact so its paid amount lands in the (restated) downstream aggregates.
--
--   A flagged late arrival that is MISSING from claim_header (or has no lines in
--   fact_claim_line) means the late-arrival / lookback window dropped data that
--   should have re-opened a prior period -- a silent under-statement of paid.
--
-- DCM domain: C (Watermark / late-arrival handling) + E (Data Quality
--   completeness) -- guards that the lookback window did not lose late rows.
--
-- Semantics: dbt SINGULAR test -- returns the late claims that went MISSING
--            downstream. Empty = PASS.
-- =============================================================================

with late as (

    select
        claim_id,
        claim_version,
        member_id,
        impacted_period
    from {{ ref('int_late_arriving_claims') }}
    where late_arrival_flag = true

),

header as (

    select claim_id, claim_version
    from {{ ref('claim_header') }}

),

lines as (

    select distinct claim_id, claim_version
    from {{ ref('fact_claim_line') }}

)

select
    l.claim_id,
    l.claim_version,
    l.member_id,
    l.impacted_period,
    iff(h.claim_id is null, true, false)                  as missing_from_header,
    iff(ln.claim_id is null, true, false)                 as missing_from_lines
from late l
left join header h
       on l.claim_id      = h.claim_id
      and l.claim_version = h.claim_version
left join lines  ln
       on l.claim_id      = ln.claim_id
      and l.claim_version = ln.claim_version
-- Violation: a flagged late arrival absent from the header OR absent from lines.
where h.claim_id  is null
   or ln.claim_id is null
