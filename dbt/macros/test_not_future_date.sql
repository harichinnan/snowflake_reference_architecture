{# =============================================================================
   macros/test_not_future_date.sql
   snowflake-claims-platform

   Generic (schema) test: asserts a date/timestamp column is not in the future.
   A claim service/submission/adjudication timestamp later than "now" indicates
   bad source data or a clock issue.

   The test returns the FAILING rows (dbt convention: 0 rows = pass).

   Params:
     model       : injected by dbt (the relation under test).
     column_name : injected by dbt (the column under test).
     allowance_days : optional slack to tolerate minor clock skew / TZ edges
                      (default 1 day). Set to 0 for strict checks.
     compare_to  : the "now" expression (default current_timestamp()); override
                   with a snapshot timestamp for deterministic tests.

   Usage (in schema.yml):
       columns:
         - name: business_event_ts
           tests:
             - not_future_date
             - not_future_date:
                 allowance_days: 0
   ============================================================================= #}

{% test not_future_date(model, column_name, allowance_days=1, compare_to='current_timestamp()') %}

select
    {{ column_name }} as failing_value
from {{ model }}
where {{ column_name }} is not null
  and {{ column_name }} > dateadd('day', {{ allowance_days }}, {{ compare_to }})

{% endtest %}
