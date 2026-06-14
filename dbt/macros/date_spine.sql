{# =============================================================================
   macros/date_spine.sql
   snowflake-claims-platform

   Package-free replacement for dbt_utils.date_spine. The trial Snowflake
   account cannot run `dbt deps`, so the date spine used by dim_date.sql is
   vendored here.

   Contract (matches dbt_utils.date_spine):
     - Signature:  date_spine(datepart, start_date, end_date)
     - start_date / end_date are SQL expressions passed as strings
       (e.g. "to_date('2018-01-01')").
     - Emits a single column named  date_<datepart>  (e.g. date_day).
     - END-EXCLUSIVE: rows run from start_date up to (but not including)
       end_date, identical to dbt_utils semantics. dim_date relies on this
       (its upper bound is 2028-01-01 to include all of 2027).

   Implementation uses Snowflake's GENERATOR table function for an efficient,
   set-based spine -- no recursion, no external package.
   ============================================================================= #}

{% macro date_spine(datepart, start_date, end_date) %}
    {#- Snowflake's GENERATOR(rowcount => ...) requires a CONSTANT argument, so we
        cannot pass datediff() directly. Instead generate a fixed, comfortably
        large candidate set and clip to the half-open [start, end) interval.
        100000 steps covers ~273 years of days (far more for month/year). -#}
    with rawdata as (
        select row_number() over (order by seq4()) - 1 as i
        from table(generator(rowcount => 100000))
    )

    select
        dateadd('{{ datepart }}', i, {{ start_date }}) as date_{{ datepart }}
    from rawdata
    -- END-EXCLUSIVE clip, matching dbt_utils.date_spine semantics.
    where dateadd('{{ datepart }}', i, {{ start_date }}) < {{ end_date }}
{% endmacro %}
