-- =============================================================================
-- dim_procedure.sql
-- Layer: SILVER_DIMENSIONAL (conformed dimension)
-- Grain: one row per procedure code (procedure_sk).
--
-- Source: seed ref_procedure_code. Carries the procedure category (e.g.
--         E&M, Surgery, Lab, Imaging, Pharmacy) used for "top procedures"
--         rollups in the GOLD condition-cost product.
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags = ['silver', 'dimensional', 'dimension', 'procedure']
  )
}}

with procedure as (

    select *
    from {{ ref('ref_procedure_code') }}

),

final as (

    select
        -- ---- surrogate key --------------------------------------------------
        {{ generate_surrogate_key(['procedure_code']) }}       as procedure_sk,

        -- ---- natural key + attributes --------------------------------------
        procedure_code,
        description,
        code_system,                                           -- e.g. CPT / HCPCS
        coalesce(procedure_category, 'Unknown')                as category,

        -- ---- audit ----------------------------------------------------------
        {{ audit_columns() }}

    from procedure

)

select * from final
