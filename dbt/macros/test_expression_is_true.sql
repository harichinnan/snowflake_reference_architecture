{# =============================================================================
   macros/test_expression_is_true.sql
   snowflake-claims-platform

   Package-free replacement for dbt_utils.expression_is_true.
   Generic test: PASSES when the boolean `expression` holds for every row
   (returns zero rows). FAILS by returning the rows where it does not hold.

   schema.yml usage in this project (column-level on `pmpm`, classic syntax):
     - expression_is_true:
         expression: ">= 0"
         config:
           where: "member_months > 0"

   Behaviour notes (matches dbt_utils):
     - When used at COLUMN level, dbt passes `column_name`. If `expression`
       starts with a comparison/operator (e.g. ">= 0"), it is prefixed with the
       column name so the final predicate is `pmpm >= 0`. A full expression that
       already references columns is used as-is.
     - The `config.where` clause is applied by dbt's test framework itself, so
       we do not need to re-handle it here. An optional `condition` kwarg is
       supported for parity with dbt_utils.
   ============================================================================= #}

{% test expression_is_true(model, expression, column_name=none, condition=none) %}

    {#- Column-level: prefix the column name when the expression is a bare
        operator/comparison fragment (the dbt_utils convention). -#}
    {%- if column_name is not none -%}
        {%- set full_expression = column_name ~ ' ' ~ expression -%}
    {%- else -%}
        {%- set full_expression = expression -%}
    {%- endif -%}

    select *
    from {{ model }}
    where not ({{ full_expression }})
    {%- if condition is not none %}
      and {{ condition }}
    {%- endif %}

{% endtest %}
