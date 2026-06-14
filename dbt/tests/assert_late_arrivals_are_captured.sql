-- =============================================================================
-- singular test: assert_late_arrivals_are_captured.sql
-- Target: silver_canonical.int_late_arriving_claims  ->  int_claim_event_deduped
--
-- Business rule
--   Late-arriving claims must NOT be silently dropped by the watermark / lookback
--   window. Every claim flagged as late-arriving (int_late_arriving_claims.
--   late_arrival_flag = true) must be CAPTURED by the pipeline, i.e. retained in
--   the canonical dedupe/capture layer (int_claim_event_deduped).
--
--   IMPORTANT: "captured" is asserted at the dedupe layer, NOT at claim_header.
--   claim_header holds only the CURRENT VALID version of each claim, so a late
--   arrival that is later voided / reversed / superseded legitimately does not
--   appear there -- that is correct claim-lifecycle behavior, not data loss. The
--   real failure mode we guard against is a late row being dropped entirely by
--   the lookback window (absent from int_claim_event_deduped), which would
--   silently under-state a prior period.
--
-- DCM domain: C (Watermark / late-arrival handling) + E (Data Quality
--   completeness).
--
-- Semantics: dbt SINGULAR test -- returns late claims the pipeline failed to
--            capture. Empty = PASS.
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

captured as (

    -- The canonical capture point: every claim version the pipeline retained
    -- after watermark/lookback filtering and dedupe.
    select distinct claim_id, claim_version
    from {{ ref('int_claim_event_deduped') }}

)

select
    l.claim_id,
    l.claim_version,
    l.member_id,
    l.impacted_period
from late l
left join captured c
       on l.claim_id      = c.claim_id
      and l.claim_version = c.claim_version
-- Violation: a flagged late arrival the pipeline dropped (never captured).
where c.claim_id is null
