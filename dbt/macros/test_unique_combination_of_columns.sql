{# =============================================================================
   macros/test_unique_combination_of_columns.sql
   snowflake-claims-platform

   Package-free replacement for dbt_utils.unique_combination_of_columns.
   Generic test: PASSES when every combination of the given columns is unique
   (i.e. returns zero rows). FAILS by returning the duplicated combinations.

   schema.yml usage (classic syntax, arg name must match `combination_of_columns`):
     - unique_combination_of_columns:
         combination_of_columns: [claim_id, claim_version]
   ============================================================================= #}

{% test unique_combination_of_columns(model, combination_of_columns) %}

    {%- set columns_csv = combination_of_columns | join(', ') -%}

    with validation_errors as (
        select
            {{ columns_csv }},
            count(*) as n_records
        from {{ model }}
        group by {{ columns_csv }}
        having count(*) > 1
    )

    select * from validation_errors

{% endtest %}
