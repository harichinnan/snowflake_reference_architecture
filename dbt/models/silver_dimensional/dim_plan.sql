-- =============================================================================
-- dim_plan.sql
-- Layer: SILVER_DIMENSIONAL (conformed dimension)
-- Grain: one row per plan (plan_sk), keyed on plan_id.
--
-- Source: silver_canonical.plan, enriched with ref_plan_type (seed) for the
--         human-readable plan-type label, and carrying a payer_sk FK so the
--         star can navigate plan -> payer without re-deriving payer keys.
--
-- Surrogate keys:
--   plan_sk  = hash(plan_id)
--   payer_sk = hash(payer_id)  (must match dim_payer's derivation exactly)
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags = ['silver', 'dimensional', 'dimension', 'plan']
  )
}}

with plan_src as (

    select *
    from {{ ref('plan') }}

),

plan_type_ref as (

    select *
    from {{ ref('ref_plan_type') }}

),

final as (

    select
        -- ---- surrogate key --------------------------------------------------
        {{ generate_surrogate_key(['plan_id']) }}             as plan_sk,

        -- ---- FK to dim_payer (same hash derivation as dim_payer) ------------
        {{ generate_surrogate_key(['payer_id']) }}            as payer_sk,

        -- ---- natural keys ---------------------------------------------------
        plan_id,
        payer_id,

        -- ---- descriptive attributes ----------------------------------------
        plan_src.plan_type,
        coalesce(t.plan_type_name, plan_src.plan_type, 'Unknown') as plan_type_name,
        plan_src.plan_name,

        -- ---- audit ----------------------------------------------------------
        {{ audit_columns() }}

    from plan_src
    left join plan_type_ref t
        on plan_src.plan_type = t.plan_type_code

)

select * from final
