-- =============================================================================
-- gold_member_months.sql
-- Layer: GOLD (CERTIFIED semantic data product)
--
-- Business question: "How many member months / distinct members did we cover by
-- payer, plan, and month?" This is the certified PMPM DENOMINATOR. Every PMPM
-- metric in the platform divides certified paid by member_months from here.
--
-- GRAIN: one row per (payer, plan, month).
-- Source: fact_eligibility_month (member x month coverage rows).
-- Certified metric: member_months (registered in SEMANTIC_METRIC_REGISTRY as
-- the PMPM denominator).
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags = ['gold', 'mart', 'semantic', 'certified', 'pmpm']
  )
}}

with elig as (

    select *
    from {{ ref('fact_eligibility_month') }}

),

dim_pay as (
    select payer_sk, payer_name, payer_type from {{ ref('dim_payer') }}
),

dim_pl as (
    select plan_sk, plan_type, plan_type_name from {{ ref('dim_plan') }}
),

dim_dt as (
    select date_sk, month_start, year_month, year, month from {{ ref('dim_date') }}
),

final as (

    select
        e.payer_sk,
        e.plan_sk,
        e.date_sk,
        dt.month_start,
        dt.year_month,
        dt.year,
        dt.month,
        pay.payer_name,
        pay.payer_type,
        pl.plan_type,
        pl.plan_type_name,

        -- ---- CERTIFIED measures --------------------------------------------
        -- member_months: total coverage-months (PMPM denominator).
        sum(e.member_month_flag)               as member_months,
        -- distinct members covered that month (semi-additive; do not sum across
        -- months for a unique-member total).
        count(distinct e.member_id)            as distinct_members

    from elig e
    left join dim_pay pay on e.payer_sk = pay.payer_sk
    left join dim_pl  pl  on e.plan_sk  = pl.plan_sk
    left join dim_dt  dt  on e.date_sk  = dt.date_sk
    group by 1,2,3,4,5,6,7,8,9,10,11

)

select * from final
