-- =============================================================================
-- fact_eligibility_month.sql
-- Layer: SILVER_DIMENSIONAL (periodic snapshot / coverage fact)
--
-- GRAIN: one row per (member, payer, plan, coverage month). Each row asserts
--        that the member was eligible for at least part of that month under
--        that payer/plan. member_month_flag = 1 always, so SUM(member_month_flag)
--        = member months -- the denominator for PMPM across the GOLD layer.
--
-- How it is built
--   silver_canonical.eligibility_span gives non-overlapping coverage spans
--   [coverage_start_date, coverage_end_date) per member/payer/plan. We EXPLODE
--   each span into its constituent calendar months by cross-joining to the
--   month-start rows of dim_date that fall within the span. A partial month of
--   coverage still counts as one member month (industry-standard "any day in
--   month" convention for this synthetic platform).
--
-- Keys
--   fact_eligibility_month_sk = hash(member_id, payer_id, plan_id, month_start)
--   FKs: patient_sk, payer_sk, plan_sk, date_sk (month_start).
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags = ['silver', 'dimensional', 'fact', 'eligibility', 'member_month']
  )
}}

with spans as (

    select *
    from {{ ref('eligibility_span') }}

),

-- One row per distinct calendar month from the date dimension.
months as (

    select distinct
        month_start,
        date_sk as month_date_sk
    from {{ ref('dim_date') }}
    where date_day = month_start          -- month-start rows only

),

-- Explode each span into the months it covers.
exploded as (

    select
        s.member_id,
        s.payer_id,
        s.plan_id,
        m.month_start,
        m.month_date_sk
    from spans s
    inner join months m
        on m.month_start >= date_trunc('month', s.coverage_start_date)
       -- end-exclusive: coverage_end_date is the first uncovered day.
       and m.month_start <  s.coverage_end_date

),

-- Defensive de-dup: overlapping spans for the same member/payer/plan must not
-- inflate member months (overlap is asserted away upstream by the
-- non-overlapping eligibility test; this keeps the fact safe regardless).
deduped as (

    select
        member_id,
        payer_id,
        plan_id,
        month_start,
        month_date_sk
    from exploded
    qualify row_number() over (
        partition by member_id, payer_id, plan_id, month_start
        order by month_start
    ) = 1

),

final as (

    select
        -- ---- surrogate key --------------------------------------------------
        {{ generate_surrogate_key(['member_id', 'payer_id', 'plan_id', 'month_start']) }}
                                                               as fact_eligibility_month_sk,

        -- ---- dimension FKs --------------------------------------------------
        {{ generate_surrogate_key(['member_id']) }}            as patient_sk,
        {{ generate_surrogate_key(['payer_id']) }}             as payer_sk,
        {{ generate_surrogate_key(['plan_id']) }}              as plan_sk,
        month_date_sk                                          as date_sk,

        -- ---- retained natural keys -----------------------------------------
        member_id,
        payer_id,
        plan_id,
        month_start,

        -- ---- the member-month measure (PMPM denominator) ------------------
        1                                                      as member_month_flag,

        -- ---- audit ----------------------------------------------------------
        {{ audit_columns() }}

    from deduped

)

select * from final
