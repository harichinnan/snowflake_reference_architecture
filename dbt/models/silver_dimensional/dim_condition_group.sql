-- =============================================================================
-- dim_condition_group.sql
-- Layer: SILVER_DIMENSIONAL (conformed dimension)
-- Grain: one row per condition group (condition_group_sk), keyed on the
--        condition-group code.
--
-- Source: seed ref_condition_group. A condition group is a clinical rollup of
--         diagnosis codes (e.g. Diabetes, CHF, COPD) used to answer cohort
--         questions like "unique members with diabetes". dim_diagnosis maps
--         each diagnosis code to one of these groups.
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags = ['silver', 'dimensional', 'dimension', 'condition_group']
  )
}}

with condition_group as (

    select *
    from {{ ref('ref_condition_group') }}

),

final as (

    select
        -- ---- surrogate key --------------------------------------------------
        {{ generate_surrogate_key(['condition_group_code']) }} as condition_group_sk,

        -- ---- natural key + attributes --------------------------------------
        condition_group_code                                   as code,
        condition_group_name                                   as name,
        description,

        -- ---- audit ----------------------------------------------------------
        {{ audit_columns() }}

    from condition_group

)

select * from final
