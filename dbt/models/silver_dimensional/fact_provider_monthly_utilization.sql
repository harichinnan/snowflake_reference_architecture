-- =============================================================================
-- fact_provider_monthly_utilization.sql
-- Layer: SILVER_DIMENSIONAL (aggregate / periodic-snapshot fact)
--
-- GRAIN: one row per (rendering provider, service month). A pre-aggregated
--        provider utilization fact built from fact_claim_line so provider-level
--        monthly rollups (claims, distinct members, paid/allowed/charge) are
--        cheap to query. Specialty is carried for slicing without a dim join.
--
-- Keys
--   fact_provider_monthly_utilization_sk = hash(provider_sk, date_sk(month))
--   FKs: provider_sk, date_sk (month_start).
--
-- Measures (additive within the month grain): claim_count,
--   distinct_member_count (semi-additive -- do NOT sum across months for a
--   unique-member total; re-aggregate from fact_claim_line for that),
--   total_paid, total_allowed, total_charge.
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags = ['silver', 'dimensional', 'fact', 'provider', 'utilization']
  )
}}

with lines as (

    select *
    from {{ ref('fact_claim_line') }}

),

provider as (

    select provider_sk, specialty
    from {{ ref('dim_provider') }}

),

month_dim as (

    select distinct month_start, date_sk as month_date_sk
    from {{ ref('dim_date') }}
    where date_day = month_start

),

agg as (

    select
        l.provider_sk,
        l.claim_month,
        count(distinct l.claim_id)         as claim_count,
        count(distinct l.member_id)        as distinct_member_count,
        sum(l.paid_amount)                 as total_paid,
        sum(l.allowed_amount)              as total_allowed,
        sum(l.charge_amount)               as total_charge,
        count(*)                           as claim_line_count
    from lines l
    group by 1, 2

),

final as (

    select
        -- ---- surrogate key --------------------------------------------------
        {{ generate_surrogate_key(['a.provider_sk', 'a.claim_month']) }}
                                                               as fact_provider_monthly_utilization_sk,

        -- ---- dimension FKs --------------------------------------------------
        a.provider_sk,
        m.month_date_sk                                        as date_sk,

        -- ---- grain attributes ----------------------------------------------
        a.claim_month                                          as month_start,
        coalesce(p.specialty, 'Unknown')                       as specialty,

        -- ---- measures -------------------------------------------------------
        a.claim_count,
        a.claim_line_count,
        a.distinct_member_count,
        a.total_paid,
        a.total_allowed,
        a.total_charge,

        -- ---- audit ----------------------------------------------------------
        {{ audit_columns() }}

    from agg a
    left join provider p
        on a.provider_sk = p.provider_sk
    left join month_dim m
        on a.claim_month = m.month_start

)

select * from final
