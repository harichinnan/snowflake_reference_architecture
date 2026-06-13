-- =============================================================================
-- analysis: cohort_builder_examples.sql
-- Layer: GOLD (read-only analysis -- compiled, not materialized)
--
-- Purpose
--   Worked examples for building member cohorts over gold_cohort_claims. The
--   model carries one row per (member_id, claim_id) decorated with the cohort
--   attributes analysts slice by (condition flags, age band, payer, plan). These
--   templates show the standard shapes: define a cohort, count distinct members,
--   sum paid, and cross-tab two dimensions.
--
-- DCM domain: J (Semantic) -- "member", "cohort", "total paid" are certified
--   semantic concepts; these queries are the reference implementations.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Diabetes cohort -- distinct members and total paid.
--    has_diabetes is a boolean condition flag pre-computed on gold_cohort_claims.
-- -----------------------------------------------------------------------------
select
    count(distinct member_id)                             as diabetes_members,
    count(distinct claim_id)                              as diabetes_claims,
    sum(paid_amount)                                      as diabetes_total_paid
from {{ ref('gold_cohort_claims') }}
where has_diabetes = true
;

-- -----------------------------------------------------------------------------
-- 2. Age band x payer cross-tab -- distinct members and paid per cell. The
--    classic cohort matrix; drop straight into a heat-map / pivot in BI.
-- -----------------------------------------------------------------------------
select
    age_band,
    payer_id,
    count(distinct member_id)                             as members,
    count(distinct claim_id)                              as claims,
    sum(paid_amount)                                      as total_paid,
    round(div0(sum(paid_amount), count(distinct member_id)), 2)
                                                          as paid_per_member
from {{ ref('gold_cohort_claims') }}
group by age_band, payer_id
order by age_band, total_paid desc
;

-- -----------------------------------------------------------------------------
-- 3. Multi-condition cohort -- members with diabetes AND hypertension, by plan.
--    Shows combining several boolean condition flags into one cohort definition.
-- -----------------------------------------------------------------------------
select
    plan_id,
    count(distinct member_id)                             as comorbid_members,
    sum(paid_amount)                                      as comorbid_total_paid
from {{ ref('gold_cohort_claims') }}
where has_diabetes     = true
  and has_hypertension = true
group by plan_id
order by comorbid_total_paid desc
;

-- -----------------------------------------------------------------------------
-- 4. Cohort size trend by month -- distinct members per service month for a
--    cohort. Useful to confirm a cohort is stable / growing before deeper work.
-- -----------------------------------------------------------------------------
select
    date_trunc('month', service_to_date)                  as service_month,
    count(distinct member_id)                             as diabetes_members
from {{ ref('gold_cohort_claims') }}
where has_diabetes = true
group by 1
order by 1
;
