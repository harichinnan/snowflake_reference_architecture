-- =============================================================================
-- gold_claims_semantic_base.sql
-- Layer: GOLD (CERTIFIED semantic data product)
--
-- The wide, conformed claims base that backs the Cortex Analyst semantic view
-- and is the access surface for the Snowflake-managed MCP server. One row per
-- fact_claim_line, denormalized against every common dimension so Analyst /
-- BI never has to author joins. Every measure here is the CERTIFIED definition;
-- see CONTROL.SEMANTIC_METRIC_REGISTRY / SEMANTIC.METRIC_REGISTRY for the
-- registered metric names this model sources (paid_amount, allowed_amount,
-- charge_amount, patient_responsibility).
--
-- GRAIN: one row per claim service line (inherits fact_claim_line grain).
--
-- Primary diagnosis: a claim can have many diagnoses; for the flat semantic
-- base we attach the PRIMARY (position 1) diagnosis and its condition group via
-- bridge_claim_diagnosis -> dim_diagnosis, so "claims for diabetes" resolves to
-- the principal condition without fanning the grain.
--
-- SYNTHETIC DATA -- certified definitions, fabricated values.
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags = ['gold', 'mart', 'semantic', 'certified']
  )
}}

with fct as (

    select *
    from {{ ref('fact_claim_line') }}

),

-- Primary diagnosis per claim (position 1) from the bridge.
primary_dx as (

    select
        b.claim_header_sk,
        b.diagnosis_sk
    from {{ ref('bridge_claim_diagnosis') }} b
    where b.is_primary = true
    qualify row_number() over (
        partition by b.claim_header_sk
        order by b.diagnosis_position
    ) = 1

),

dim_dx as (
    select diagnosis_sk, diagnosis_code, description as diagnosis_description,
           condition_group, condition_group_sk
    from {{ ref('dim_diagnosis') }}
),

dim_pat as (
    select patient_sk, member_id, age_band, gender, state as member_state, zip3 as member_zip3
    from {{ ref('dim_patient') }}
),

dim_prov as (
    select provider_sk, npi, provider_name, specialty as provider_specialty,
           provider_type, state as provider_state
    from {{ ref('dim_provider') }}
),

dim_pay as (
    select payer_sk, payer_id, payer_name, payer_type
    from {{ ref('dim_payer') }}
),

dim_pl as (
    select plan_sk, plan_id, plan_type, plan_type_name
    from {{ ref('dim_plan') }}
),

dim_dt as (
    select date_sk, date_day as service_date, year, quarter, month, month_name,
           month_start, year_month
    from {{ ref('dim_date') }}
),

dim_proc as (
    select procedure_sk, procedure_code, description as procedure_description, category as procedure_category
    from {{ ref('dim_procedure') }}
),

final as (

    select
        -- ---- keys -----------------------------------------------------------
        f.fact_claim_line_sk,
        f.claim_id,
        f.claim_line_id,
        f.claim_version,
        f.claim_header_sk,

        -- ---- date / period --------------------------------------------------
        f.date_sk,
        dt.service_date,
        f.claim_month,
        f.service_year,
        dt.year_month,
        dt.quarter,
        dt.month_name,

        -- ---- patient --------------------------------------------------------
        f.patient_sk,
        pat.member_id,
        pat.age_band,
        pat.gender,
        pat.member_state,
        pat.member_zip3,

        -- ---- provider -------------------------------------------------------
        f.provider_sk,
        prov.npi                                   as provider_npi,
        prov.provider_name,
        prov.provider_specialty,
        prov.provider_type,
        prov.provider_state,

        -- ---- payer / plan ---------------------------------------------------
        f.payer_sk,
        pay.payer_name,
        pay.payer_type,
        f.plan_sk,
        pl.plan_type,
        pl.plan_type_name,

        -- ---- procedure ------------------------------------------------------
        f.procedure_sk,
        proc.procedure_code,
        proc.procedure_description,
        proc.procedure_category,

        -- ---- primary diagnosis / condition ---------------------------------
        dx.diagnosis_code                          as primary_diagnosis_code,
        dx.diagnosis_description                   as primary_diagnosis_description,
        coalesce(dx.condition_group, 'Ungrouped')  as condition_group,

        -- ---- classification / flags ----------------------------------------
        f.claim_type,
        f.claim_status,
        f.claim_setting,
        f.denial_flag,
        f.denial_reason_code,
        f.adjustment_flag,
        f.reversal_flag,

        -- ---- CERTIFIED measures (additive) ---------------------------------
        f.charge_amount,
        f.allowed_amount,
        f.paid_amount,
        f.patient_responsibility,
        f.units

    from fct f
    left join dim_dt   dt   on f.date_sk        = dt.date_sk
    left join dim_pat  pat  on f.patient_sk     = pat.patient_sk
    left join dim_prov prov on f.provider_sk    = prov.provider_sk
    left join dim_pay  pay  on f.payer_sk       = pay.payer_sk
    left join dim_pl   pl   on f.plan_sk        = pl.plan_sk
    left join dim_proc proc on f.procedure_sk   = proc.procedure_sk
    left join primary_dx pdx on f.claim_header_sk = pdx.claim_header_sk
    left join dim_dx   dx   on pdx.diagnosis_sk = dx.diagnosis_sk

)

select * from final
