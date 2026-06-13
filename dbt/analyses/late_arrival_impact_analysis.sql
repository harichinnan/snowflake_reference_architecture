-- =============================================================================
-- analysis: late_arrival_impact_analysis.sql
-- Layer: GOLD (read-only analysis -- compiled, not materialized)
--
-- Purpose
--   Quantify how late-arriving claims restate already-closed prior periods.
--   gold_late_arrival_impact stores, per impacted (closed) period, the paid
--   total BEFORE the late arrivals were folded in and the paid total AFTER, so
--   finance can see exactly which months moved and by how much.
--
--   "Restatement" here means: a period's books were closed at paid_before_amount;
--   late-arriving claims (flagged upstream in int_late_arriving_claims, grace
--   window var late_arrival_default_days = 7) landed afterward and the period
--   was re-opened to paid_after_amount. The delta is the restatement amount.
--
-- DCM domains: C (Watermark) + the late-arrival handling that protects prior
--   periods; J (Semantic) for the certified "paid" measure.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Before / after paid totals per impacted period, with the restatement delta.
--    Only periods that actually moved (delta <> 0) are interesting.
-- -----------------------------------------------------------------------------
select
    impacted_period,
    paid_before_amount,
    paid_after_amount,
    paid_after_amount - paid_before_amount                as restatement_amount,
    round(
        div0(paid_after_amount - paid_before_amount, nullif(paid_before_amount, 0)) * 100,
        2)                                                as restatement_pct,
    late_arrival_claim_count
from {{ ref('gold_late_arrival_impact') }}
where paid_after_amount <> paid_before_amount
order by abs(paid_after_amount - paid_before_amount) desc
;

-- -----------------------------------------------------------------------------
-- 2. Total restatement exposure across all periods -- a single finance KPI.
-- -----------------------------------------------------------------------------
select
    count(*)                                              as periods_restated,
    sum(late_arrival_claim_count)                         as total_late_claims,
    sum(paid_after_amount - paid_before_amount)           as net_restatement_amount
from {{ ref('gold_late_arrival_impact') }}
where paid_after_amount <> paid_before_amount
;

-- -----------------------------------------------------------------------------
-- 3. Drill-down: the individual late-arriving claims behind a chosen impacted
--    period. Joins the gold impact rollup back to the canonical late-arrival
--    intermediate so an analyst can see claim-level lag and impacted_period.
--    Swap the literal period to investigate a specific restated month.
-- -----------------------------------------------------------------------------
select
    la.claim_id,
    la.claim_version,
    la.member_id,
    la.service_to_date,
    la.received_date,
    la.received_lag_days,
    la.impacted_period
from {{ ref('int_late_arriving_claims') }} la
where la.late_arrival_flag = true
  and la.impacted_period   = date '2026-01-01'    -- <-- choose the restated period
order by la.received_lag_days desc
;
