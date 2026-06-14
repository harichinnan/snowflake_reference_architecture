-- =============================================================================
-- dim_date.sql
-- Layer: SILVER_DIMENSIONAL (conformed date dimension)
-- Grain: one row per calendar day.
--
-- A generated date spine (local date_spine macro) covering 2018-01-01 through
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

    -- 13 full calendar years of days. date_spine is end-exclusive, so the upper
    -- bound is 2031-01-01 to include all of 2030. The range must cover every
    -- service/fill/event date in the data INCLUDING late- and future-dated
    -- synthetic claims (some land in 2028); otherwise fact date_sk FKs and any
    -- month_start lookups resolve to NULL.
    {{ date_spine(
        datepart = "day",
        start_date = "to_date('2018-01-01')",
        end_date   = "to_date('2031-01-01')"
    ) }}

),

final as (

    select
        -- date_day is the column emitted by the local date_spine macro
        -- (column name is date_<datepart>, datepart='day' -> date_day).
        cast(date_day as date)                                 as date_day,

        -- ---- integer surrogate key (yyyymmdd) ------------------------------
        cast(to_char(date_day, 'YYYYMMDD') as integer)         as date_sk,

        -- ---- calendar parts -------------------------------------------------
        year(date_day)                                         as year,
        quarter(date_day)                                      as quarter,
        month(date_day)                                        as month,
        monthname(date_day)                                    as month_name,
        day(date_day)                                          as day,

        -- Snowflake DAYOFWEEK: 0=Sunday .. 6=Saturday (WEEK_START dependent;
        -- we use the ISO-style dayofweekiso 1=Mon..7=Sun for stability).
        dayofweekiso(date_day)                                 as day_of_week,
        case when dayofweekiso(date_day) in (6, 7) then true else false end
                                                               as is_weekend,

        -- ---- period anchors -------------------------------------------------
        date_trunc('month', date_day)::date                    as month_start,
        date_trunc('year',  date_day)::date                    as year_start,
        to_char(date_day, 'YYYY-MM')                            as year_month

    from spine

)

select * from final
