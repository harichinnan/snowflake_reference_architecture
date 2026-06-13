{# =============================================================================
   macros/test_amount_nonnegative_or_adjustment.sql
   snowflake-claims-platform

   Generic (schema) test: an amount column must be >= 0 UNLESS the record is a
   legitimate negative-amount event (adjustment / reversal / void / recoupment).
   Negative charges/payments are only valid in those contexts.

   Returns FAILING rows (negative amount that is NOT an allowed negative type).

   Params:
     model        : injected by dbt.
     column_name  : injected by dbt (the amount column).
     type_column  : column holding the record/event type to inspect
                    (default 'record_type').
     allowed_negative_types : list of type values for which negatives are OK
                    (default ['ADJUSTMENT','REVERSAL','VOID','RECOUPMENT']).
     is_adjustment_flag : optional boolean column that, when true, also permits
                    a negative amount (default none -> ignored).

   Usage (in schema.yml):
       columns:
         - name: paid_amount
           tests:
             - amount_nonnegative_or_adjustment:
                 type_column: adjudication_type
                 allowed_negative_types: ['ADJUSTMENT','REVERSAL','RECOUPMENT']
   ============================================================================= #}

{% test amount_nonnegative_or_adjustment(
        model,
        column_name,
        type_column='record_type',
        allowed_negative_types=['ADJUSTMENT','REVERSAL','VOID','RECOUPMENT'],
        is_adjustment_flag=none
    ) %}

select
    {{ column_name }} as failing_amount,
    {{ type_column }} as failing_type
from {{ model }}
where {{ column_name }} is not null
  and {{ column_name }} < 0
  -- allowed if the type is one of the negative-permitting event types ...
  and upper(coalesce({{ type_column }}::string, '')) not in (
        {%- for t in allowed_negative_types -%}
        '{{ t | upper }}'{% if not loop.last %}, {% endif %}
        {%- endfor -%}
      )
  {%- if is_adjustment_flag is not none %}
  -- ... or explicitly flagged as an adjustment row
  and coalesce({{ is_adjustment_flag }}, false) = false
  {%- endif %}

{% endtest %}
