-- =============================================================================
-- gold_payer_plan_summary.sql
-- Layer: GOLD (CERTIFIED semantic data product)
--
-- Business question: "What are paid/allowed/charge, PMPM, and denial rate by
-- payer, plan, and month?" The headline payer P&L + PMPM product.
--
-- GRAIN: one row per (payer, plan, month).
--
-- PMPM is the CERTIFIED metric paid / member_months, where member_months comes
-- from gold_member_months (the single certified denominator). We join claims
-- (numerator) to member months (denominator) on payer/plan/month so PMPM means
-- exactly one thing platform-wide. See SEMANTIC_METRIC_REGISTRY: pmpm,
-- denial_rate, paid_amount.
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags = ['gold', 'mart', 'semantic', 'certified', 'pmpm', 'payer']
  )
}}

with base as (

    select *
    from {{ ref('gold_claims_semantic_base') }}

),

claims_agg as (

    select
        payer_sk,
        plan_sk,
        claim_month,
        payer_name,
        payer_type,
        plan_type,
        plan_type_name,
        sum(paid_amount)                       as total_paid,
        sum(allowed_amount)                    as total_allowed,
        sum(charge_amount)                     as total_charge,
        sum(patient_responsibility)            as total_patient_responsibility,
        count(distinct claim_id)               as claim_count,
        count(*)                               as claim_line_count,
        sum(case when denial_flag then 1 else 0 end)         as denied_line_count,
        count(distinct case when denial_flag then claim_id end) as denied_claim_count
    from base
    group by 1,2,3,4,5,6,7

),

member_months as (

    select payer_sk, plan_sk, month_start, member_months
    from {{ ref('gold_member_months') }}

),

final as (

    select
        c.payer_sk,
        c.plan_sk,
        c.claim_month                          as month_start,
        c.payer_name,
        c.payer_type,
        c.plan_type,
        c.plan_type_name,

        -- ---- certified measures --------------------------------------------
        c.total_paid,
        c.total_allowed,
        c.total_charge,
        c.total_patient_responsibility,
        c.claim_count,
        c.claim_line_count,
        coalesce(mm.member_months, 0)          as member_months,

        -- PMPM (certified): paid / member months. Null-safe: 0 member months -> NULL.
        case when coalesce(mm.member_months, 0) > 0
             then c.total_paid / mm.member_months else null end
                                               as pmpm,

        -- denial metrics
        c.denied_claim_count,
        c.denied_line_count,
        case when c.claim_count > 0
             then c.denied_claim_count::float / c.claim_count else 0 end
                                               as denial_rate

    from claims_agg c
    left join member_months mm
        on c.payer_sk = mm.payer_sk
       and c.plan_sk  = mm.plan_sk
       and c.claim_month = mm.month_start

)

select * from final
