-- =============================================================================
-- analysis: provider_utilization_workbook_queries.sql
-- Layer: GOLD (read-only analysis -- compiled, not materialized)
--
-- Purpose
--   Reusable "provider utilization workbook" queries. Analysts pull these into a
--   worksheet to profile provider activity by specialty and month, and to find
--   the providers driving cost for a given clinical condition group.
--
--   Joins gold_provider_utilization (provider x month utilization facts) with
--   gold_condition_cost_summary (condition-group cost rollups) on the shared
--   provider / period grain.
--
-- DCM domain: J (Semantic) -- these mirror certified semantic metrics.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Provider utilization by specialty and month. Rolls the provider grain up
--    to specialty so trends are readable. paid_amount / claim_count / unique
--    members come straight from the curated gold model.
-- -----------------------------------------------------------------------------
select
    specialty,
    utilization_month,
    count(distinct provider_npi)                          as active_providers,
    sum(claim_count)                                      as claim_count,
    sum(distinct_member_count)                            as distinct_members,
    sum(total_paid_amount)                                as total_paid_amount,
    round(div0(sum(total_paid_amount), sum(claim_count)), 2)
                                                          as paid_per_claim
from {{ ref('gold_provider_utilization') }}
group by specialty, utilization_month
order by utilization_month, total_paid_amount desc
;

-- -----------------------------------------------------------------------------
-- 2. Top 25 providers by paid amount for a chosen condition group. Joins the
--    provider utilization fact to the condition-cost summary on provider +
--    month, then filters to the condition group of interest.
--    Swap the literal in the WHERE clause for the condition group you want.
-- -----------------------------------------------------------------------------
with condition_cost as (

    select
        provider_npi,
        utilization_month,
        condition_group,
        condition_paid_amount,
        condition_claim_count
    from {{ ref('gold_condition_cost_summary') }}
    where condition_group = 'DIABETES'           -- <-- parameterize per workbook

),

provider_util as (

    select
        provider_npi,
        specialty,
        utilization_month,
        total_paid_amount,
        claim_count
    from {{ ref('gold_provider_utilization') }}

)

select
    pu.provider_npi,
    pu.specialty,
    cc.condition_group,
    sum(cc.condition_paid_amount)                          as condition_paid_amount,
    sum(cc.condition_claim_count)                          as condition_claim_count,
    sum(pu.total_paid_amount)                              as all_paid_amount
from provider_util       pu
join condition_cost      cc
  on pu.provider_npi      = cc.provider_npi
 and pu.utilization_month = cc.utilization_month
group by pu.provider_npi, pu.specialty, cc.condition_group
order by condition_paid_amount desc
limit 25
;

-- -----------------------------------------------------------------------------
-- 3. Specialty mix for a condition group -- which specialties carry the cost.
-- -----------------------------------------------------------------------------
select
    pu.specialty,
    sum(cc.condition_paid_amount)                          as condition_paid_amount,
    round(
        div0(
            sum(cc.condition_paid_amount),
            sum(sum(cc.condition_paid_amount)) over ()
        ) * 100, 2)                                        as pct_of_condition_paid
from {{ ref('gold_provider_utilization') }}     pu
join {{ ref('gold_condition_cost_summary') }}   cc
  on pu.provider_npi      = cc.provider_npi
 and pu.utilization_month = cc.utilization_month
where cc.condition_group = 'DIABETES'            -- <-- parameterize per workbook
group by pu.specialty
order by condition_paid_amount desc
;
