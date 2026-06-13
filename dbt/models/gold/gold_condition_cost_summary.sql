-- =============================================================================
-- gold_condition_cost_summary.sql
-- Layer: GOLD (CERTIFIED semantic data product)
--
-- Business questions:
--   - "How many UNIQUE MEMBERS have diabetes (or any condition group)?"
--   - "What is total/per-member cost by condition?"
--   - "What are the TOP PROVIDERS / TOP PROCEDURES for a condition?"
--
-- GRAIN: one row per (condition_group, month). Built from the certified
-- semantic base so the condition attribution (primary diagnosis -> condition
-- group) is identical to everything else. top_procedures is a small ARRAY of
-- the highest-paid procedure categories within the condition-month.
--
-- Certified metrics: distinct_members_with_condition, total_paid,
--   paid_per_member (see SEMANTIC_METRIC_REGISTRY).
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags = ['gold', 'mart', 'semantic', 'certified', 'condition']
  )
}}

with base as (

    select *
    from {{ ref('gold_claims_semantic_base') }}

),

-- Rank procedure categories by paid within each condition-month so we can
-- surface the top contributors.
proc_rank as (

    select
        condition_group,
        claim_month,
        procedure_category,
        sum(paid_amount)                   as cat_paid,
        row_number() over (
            partition by condition_group, claim_month
            order by sum(paid_amount) desc
        )                                  as rn
    from base
    group by 1,2,3

),

top_procs as (
    select
        condition_group,
        claim_month,
        array_agg(procedure_category) within group (order by rn) as top_procedures
    from proc_rank
    where rn <= 5
    group by 1,2
),

agg as (

    select
        condition_group,
        claim_month,
        count(distinct member_id)          as distinct_members_with_condition,
        count(distinct claim_id)           as claims,
        sum(paid_amount)                   as total_paid,
        sum(allowed_amount)                as total_allowed,
        sum(charge_amount)                 as total_charge
    from base
    group by 1,2

),

final as (

    select
        a.condition_group,
        a.claim_month,
        a.distinct_members_with_condition,
        a.claims,
        a.total_paid,
        a.total_allowed,
        a.total_charge,
        case when a.distinct_members_with_condition > 0
             then a.total_paid / a.distinct_members_with_condition else 0 end
                                           as paid_per_member,
        t.top_procedures
    from agg a
    left join top_procs t
        on a.condition_group = t.condition_group
       and a.claim_month = t.claim_month

)

select * from final
