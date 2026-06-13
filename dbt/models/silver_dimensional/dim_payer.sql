-- =============================================================================
-- dim_payer.sql
-- Layer: SILVER_DIMENSIONAL (conformed dimension)
-- Grain: one row per payer (payer_sk), keyed on payer_id.
--
-- Source: silver_canonical.payer.
--
-- payer_type / payer_category is a conformed, governed categorization used as a
-- top-level slicer across GOLD products (Commercial / Medicare / Medicaid /
-- Other). It is normalized here so every downstream metric means the same
-- thing. Accepted values are tested in schema.yml.
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags = ['silver', 'dimensional', 'dimension', 'payer']
  )
}}

with payer as (

    select *
    from {{ ref('payer') }}

),

final as (

    select
        -- ---- surrogate key --------------------------------------------------
        {{ generate_surrogate_key(['payer_id']) }}            as payer_sk,

        -- ---- natural key ----------------------------------------------------
        payer_id,

        -- ---- descriptive attributes ----------------------------------------
        payer_name,

        -- Conformed payer category (the governed "payer_type" slicer). Normalize
        -- whatever casing/synonyms the canonical layer carries into a small,
        -- stable accepted-value set.
        case
            when upper(coalesce(payer_category, payer_type)) like '%COMMERCIAL%' then 'Commercial'
            when upper(coalesce(payer_category, payer_type)) like '%MEDICARE%'   then 'Medicare'
            when upper(coalesce(payer_category, payer_type)) like '%MEDICAID%'   then 'Medicaid'
            else 'Other'
        end                                                   as payer_type,

        coalesce(payer_category, payer_type)                  as payer_category_raw,

        -- ---- audit ----------------------------------------------------------
        {{ audit_columns() }}

    from payer

)

select * from final
