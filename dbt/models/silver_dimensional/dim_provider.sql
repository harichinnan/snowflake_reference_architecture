-- =============================================================================
-- dim_provider.sql
-- Layer: SILVER_DIMENSIONAL (conformed dimension)
-- Grain: one row per provider (provider_sk), keyed on NPI.
--
-- Source: silver_canonical.provider, enriched with ref_provider_specialty
--         (seed) to resolve the specialty taxonomy code into a human-readable
--         specialty / provider-type grouping.
--
-- Surrogate key:
--   provider_sk = hash(npi). NPI is the natural key for both rendering and
--   billing roles; facts reference this dimension multiple times (rendering,
--   billing, prescriber, pharmacy) by re-joining on the relevant NPI.
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags = ['silver', 'dimensional', 'dimension', 'provider']
  )
}}

with provider as (

    select *
    from {{ ref('provider') }}

),

specialty_ref as (

    select *
    from {{ ref('ref_provider_specialty') }}

),

joined as (

    select
        p.*,
        s.specialty_name,
        s.provider_type as ref_provider_type
    from provider p
    left join specialty_ref s
        on p.specialty_code = s.specialty_code

),

final as (

    select
        -- ---- surrogate key --------------------------------------------------
        {{ generate_surrogate_key(['npi']) }}                 as provider_sk,

        -- ---- natural key ----------------------------------------------------
        npi,

        -- ---- descriptive attributes ----------------------------------------
        provider_name,
        specialty_code,
        coalesce(specialty_name, 'Unknown')                   as specialty,
        taxonomy_code                                         as taxonomy,

        -- Provider type: prefer the reference rollup, fall back to canonical.
        coalesce(ref_provider_type, provider_type, 'Unknown') as provider_type,

        -- ---- synthetic geography -------------------------------------------
        state,
        left(coalesce(zip_code, ''), 3)                       as zip3,

        -- ---- audit ----------------------------------------------------------
        {{ audit_columns() }}

    from joined

)

select * from final
