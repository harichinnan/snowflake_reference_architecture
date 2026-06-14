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
        -- ref_provider_specialty is keyed by taxonomy_code (canonical provider has
        -- no specialty_code) and exposes specialty_code + specialty_name. It has
        -- NO provider_type column.
        s.specialty_code as ref_specialty_code,
        s.specialty_name
    from provider p
    left join specialty_ref s
        on p.taxonomy_code = s.taxonomy_code

),

final as (

    select
        -- ---- surrogate key --------------------------------------------------
        {{ generate_surrogate_key(['npi']) }}                 as provider_sk,

        -- ---- natural key ----------------------------------------------------
        npi,

        -- ---- descriptive attributes ----------------------------------------
        provider_name,
        ref_specialty_code                                    as specialty_code,
        -- Prefer the reference specialty name; fall back to the canonical
        -- free-text specialty carried on the provider master.
        coalesce(specialty_name, specialty, 'Unknown')        as specialty,
        taxonomy_code                                         as taxonomy,

        -- Provider type comes only from the canonical provider master
        -- (ref_provider_specialty has no provider_type).
        coalesce(provider_type, 'Unknown')                    as provider_type,

        -- ---- geography ------------------------------------------------------
        -- The canonical provider master carries no parsed state/zip (addresses
        -- live unparsed in addresses_raw), so geography is NULL here.
        cast(null as string)                                  as state,
        cast(null as string)                                  as zip3,

        -- ---- audit ----------------------------------------------------------
        {{ audit_columns() }}

    from joined

)

select * from final
