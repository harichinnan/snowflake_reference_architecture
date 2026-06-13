-- =============================================================================
-- gold_cohort_claims.sql
-- Layer: GOLD (CERTIFIED semantic data product)
--
-- Business question: "Build a member cohort by condition / age band / payer and
-- give me their claim metrics." A cohort-friendly grain that lets Analyst / BI
-- filter members into cohorts and aggregate certified measures consistently.
--
-- GRAIN: one row per (member, condition_group, age_band, payer_type, claim_month).
-- Filterable to define a cohort (e.g. condition_group = 'Diabetes' and
-- age_band = '50-64' and payer_type = 'Medicare'). Member-level so distinct
-- member counts are exact after filtering.
--
-- Certified measures: total_paid, total_allowed, claims, distinct_members
-- (count distinct member_id after your cohort filter).
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags = ['gold', 'mart', 'semantic', 'certified', 'cohort']
  )
}}

with base as (

    select *
    from {{ ref('gold_claims_semantic_base') }}

),

final as (

    select
        -- ---- cohort dimensions ---------------------------------------------
        member_id,
        patient_sk,
        condition_group,
        age_band,
        gender,
        payer_type,
        payer_sk,
        plan_sk,
        claim_month,
        service_year,

        -- ---- certified measures (member x condition x month) ---------------
        count(distinct claim_id)               as claims,
        count(*)                               as claim_lines,
        sum(paid_amount)                       as total_paid,
        sum(allowed_amount)                    as total_allowed,
        sum(charge_amount)                     as total_charge,
        sum(patient_responsibility)            as total_patient_responsibility,
        max(case when denial_flag then 1 else 0 end) as any_denial_flag

    from base
    group by 1,2,3,4,5,6,7,8,9,10

)

select * from final
