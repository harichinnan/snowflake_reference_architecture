-- =============================================================================
-- dim_date.sql
-- Layer: SILVER_DIMENSIONAL (conformed date dimension)
-- Grain: one row per calendar day.
--
-- A generated date spine (dbt_utils.date_spine) covering 2018-01-01 through
-- 2027-12-31 -- wide enough to span synthetic service dates, fill dates, event
-- timestamps, and the eligibility month explosion (fact_eligibility_month)
-- with headroom on both ends.
--
-- date_sk is the integer yyyymmdd surrogate (e.g. 2024-03-15 -> 20240315). All
-- facts reference this dimension by date_sk so date logic lives in exactly one
-- place. month_start + year_month support the monthly grain used across GOLD.
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags = ['silver', 'dimensional', 'dimension', 'date']
  )
}}

with spine as (

    -- 10 full calendar years of days. date_spine is end-exclusive, so the upper
    -- bound is 2028-01-01 to include all of 2027.
    {{ dbt_utils.date_spine(
        datepart = "day",
        start_date = "to_date('2018-01-01')",
        end_date   = "to_date('2028-01-01')"
    ) }}

),

final as (

    select
        -- date_d is the column dbt_utils.date_spine emits.
        cast(date_d as date)                                   as date_day,

        -- ---- integer surrogate key (yyyymmdd) ------------------------------
        cast(to_char(date_d, 'YYYYMMDD') as integer)           as date_sk,

        -- ---- calendar parts -------------------------------------------------
        year(date_d)                                           as year,
        quarter(date_d)                                        as quarter,
        month(date_d)                                          as month,
        monthname(date_d)                                      as month_name,
        day(date_d)                                            as day,

        -- Snowflake DAYOFWEEK: 0=Sunday .. 6=Saturday (WEEK_START dependent;
        -- we use the ISO-style dayofweekiso 1=Mon..7=Sun for stability).
        dayofweekiso(date_d)                                   as day_of_week,
        case when dayofweekiso(date_d) in (6, 7) then true else false end
                                                               as is_weekend,

        -- ---- period anchors -------------------------------------------------
        date_trunc('month', date_d)::date                      as month_start,
        date_trunc('year',  date_d)::date                      as year_start,
        to_char(date_d, 'YYYY-MM')                             as year_month

    from spine

)

select * from final
