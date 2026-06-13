-- =============================================================================
-- gold_provider_utilization.sql
-- Layer: GOLD (CERTIFIED semantic data product)
--
-- Business question: "Which providers / specialties drive utilization and cost,
-- and what are the per-member rates?" Provider utilization by specialty and
-- synthetic geography (state) by month.
--
-- GRAIN: one row per (provider, specialty, state, month).
-- Source: fact_provider_monthly_utilization + dim_provider.
-- Certified metrics: claims, distinct_members, total_paid/allowed,
--   paid_per_member, claims_per_member (see SEMANTIC_METRIC_REGISTRY).
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags = ['gold', 'mart', 'semantic', 'certified', 'provider']
  )
}}

with util as (

    select *
    from {{ ref('fact_provider_monthly_utilization') }}

),

dim_prov as (
    select provider_sk, npi, provider_name, specialty, provider_type, state
    from {{ ref('dim_provider') }}
),

dim_dt as (
    select date_sk, month_start, year_month, year, month from {{ ref('dim_date') }}
),

final as (

    select
        u.provider_sk,
        p.npi                                  as provider_npi,
        p.provider_name,
        coalesce(p.specialty, 'Unknown')       as specialty,
        coalesce(p.state, 'Unknown')           as provider_state,
        u.date_sk,
        dt.month_start,
        dt.year_month,
        dt.year,
        dt.month,

        -- ---- certified measures --------------------------------------------
        u.claim_count                          as claims,
        u.claim_line_count                     as claim_lines,
        u.distinct_member_count                as distinct_members,
        u.total_paid,
        u.total_allowed,
        u.total_charge,

        -- ---- per-member rates ----------------------------------------------
        case when u.distinct_member_count > 0
             then u.total_paid / u.distinct_member_count else 0 end
                                               as paid_per_member,
        case when u.distinct_member_count > 0
             then u.claim_count::float / u.distinct_member_count else 0 end
                                               as claims_per_member

    from util u
    left join dim_prov p on u.provider_sk = p.provider_sk
    left join dim_dt   dt on u.date_sk    = dt.date_sk

)

select * from final
