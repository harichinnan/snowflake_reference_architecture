{# =============================================================================
   macros/test_recency.sql
   snowflake-claims-platform

   Package-free replacement for dbt_utils.recency.
   Generic test: PASSES when the most recent value of `field` is no older than
   `interval` `datepart`s before now (returns zero rows). FAILS by returning a
   single summary row when the data is stale.

   schema.yml usage in this project (model-level, classic syntax):
     - recency:
         datepart: day
         field: service_from_date
         interval: 400

   Behaviour notes (matches dbt_utils):
     - Threshold = dateadd(datepart, -interval, <now>).
     - Uses current_timestamp as "now" (dbt_utils dispatches to a per-adapter
       now expression; on Snowflake that is effectively current_timestamp).
     - Extra optional kwargs that dbt_utils accepts (group_by_columns,
       ignore_time_component) are declared with defaults so the test never errors
       on signature mismatch. They are intentionally not used by this minimal
       implementation (the project's single usage passes only field/datepart/interval).
   ============================================================================= #}

{% test recency(model, field, datepart, interval, group_by_columns=none, ignore_time_component=false) %}

    {%- set threshold = "dateadd('" ~ datepart ~ "', -" ~ interval ~ ", current_timestamp)" -%}

    with recency as (
        select max({{ field }}) as most_recent
        from {{ model }}
    )

    select most_recent
    from recency
    where most_recent < {{ threshold }}

{% endtest %}
