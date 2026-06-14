{# =============================================================================
   macros/test_accepted_range.sql
   snowflake-claims-platform

   Package-free replacement for dbt_utils.accepted_range.
   Generic test: PASSES when every non-null value of `column_name` lies within
   [min_value, max_value] (bounds optional). FAILS by returning out-of-range rows.

   schema.yml usage (column-level, classic syntax):
     - accepted_range:
         min_value: 0
         inclusive: true
     - accepted_range:
         min_value: 0
         max_value: 1
         inclusive: true

   Notes vs dbt_utils:
     - Only NON-NULL values are evaluated (nulls never fail), matching dbt_utils.
     - `inclusive` defaults to true. When true, a value equal to a bound passes;
       when false, equality to a bound fails.
     - Either bound may be omitted; the predicate is built to stay valid SQL.
   ============================================================================= #}

{% test accepted_range(model, column_name, min_value=none, max_value=none, inclusive=true) %}

    {%- set lower_op = '<' if inclusive else '<=' -%}
    {%- set upper_op = '>' if inclusive else '>=' -%}

    with validation_errors as (
        select {{ column_name }}
        from {{ model }}
        where {{ column_name }} is not null
          and (
            false
            {%- if min_value is not none %}
            or {{ column_name }} {{ lower_op }} {{ min_value }}
            {%- endif %}
            {%- if max_value is not none %}
            or {{ column_name }} {{ upper_op }} {{ max_value }}
            {%- endif %}
          )
    )

    select * from validation_errors

{% endtest %}
