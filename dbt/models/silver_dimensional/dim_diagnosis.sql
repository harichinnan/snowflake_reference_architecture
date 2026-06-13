-- =============================================================================
-- dim_diagnosis.sql
-- Layer: SILVER_DIMENSIONAL (conformed dimension)
-- Grain: one row per diagnosis code (diagnosis_sk).
--
-- Source: seed ref_diagnosis_code, left-joined to ref_condition_group via the
--         diagnosis code's condition-group mapping so each diagnosis carries
--         its clinical rollup. This is the dimension the diagnosis bridge and
--         the GOLD condition-cost product join to.
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags = ['silver', 'dimensional', 'dimension', 'diagnosis']
  )
}}

with diagnosis as (

    select *
    from {{ ref('ref_diagnosis_code') }}

),

condition_group as (

    select *
    from {{ ref('ref_condition_group') }}

),

final as (

    select
        -- ---- surrogate key --------------------------------------------------
        {{ generate_surrogate_key(['d.diagnosis_code']) }}     as diagnosis_sk,

        -- ---- natural key + attributes --------------------------------------
        d.diagnosis_code,
        d.description,
        d.code_system,                                          -- e.g. ICD-10-CM

        -- ---- clinical rollup -----------------------------------------------
        coalesce(cg.condition_group_code, 'UNGROUPED')         as condition_group_code,
        coalesce(cg.condition_group_name, 'Ungrouped')         as condition_group,

        -- FK to dim_condition_group (same hash derivation).
        {{ generate_surrogate_key(['coalesce(cg.condition_group_code, \'UNGROUPED\')']) }}
                                                               as condition_group_sk,

        -- ---- audit ----------------------------------------------------------
        {{ audit_columns() }}

    from diagnosis d
    left join condition_group cg
        on d.condition_group_code = cg.condition_group_code

)

select * from final
