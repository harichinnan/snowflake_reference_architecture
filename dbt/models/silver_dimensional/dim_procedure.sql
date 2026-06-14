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

-- CONFORMED dimension: cover EVERY procedure code observed in claims UNION the
-- reference seed, so the procedure bridge's FK to this dim holds for real codes
-- outside the catalog. (Out-of-catalog codes remain flagged by the warn-severity
-- claim_procedure.procedure_code -> ref_procedure_code relationship test.)
with observed as (

    select distinct procedure_code
    from {{ ref('claim_procedure') }}
    where procedure_code is not null

),

seed as (

    select *
    from {{ ref('ref_procedure_code') }}

),

all_codes as (

    select procedure_code from observed
    union
    select procedure_code from seed

),

final as (

    select
        -- ---- surrogate key --------------------------------------------------
        {{ generate_surrogate_key(['ac.procedure_code']) }}    as procedure_sk,

        -- ---- natural key + attributes --------------------------------------
        ac.procedure_code,
        -- ref_procedure_code carries short_description + category; expose them
        -- under the downstream names. Observed-but-unmapped codes get placeholders.
        coalesce(s.short_description, 'Unmapped procedure (not in reference catalog)')
                                                               as description,
        coalesce(s.code_system, 'UNKNOWN')                     as code_system,  -- e.g. CPT / HCPCS
        coalesce(s.category, 'Unknown')                        as category,

        -- ---- audit ----------------------------------------------------------
        {{ audit_columns() }}

    from all_codes ac
    left join seed s
        on ac.procedure_code = s.procedure_code

)

select * from final
