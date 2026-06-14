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
        -- ref_procedure_code carries short_description + category (not
        -- description / procedure_category); expose them under the downstream names.
        short_description as description,
        code_system,                                           -- e.g. CPT / HCPCS
        coalesce(category, 'Unknown')                          as category,

        -- ---- audit ----------------------------------------------------------
        {{ audit_columns() }}

    from procedure

)

select * from final
