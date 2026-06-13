{# =============================================================================
   macros/test_claim_header_line_reconciliation.sql
   snowflake-claims-platform

   Generic (schema) test: the claim header total must equal the sum of its line
   amounts, within a tolerance. Catches split/merge/rounding defects between the
   header model and the line model.

   This is a relationship-style test declared on the HEADER model; it joins to
   the LINE model on the claim key and compares header_amount to SUM(line_amount).

   Returns FAILING rows: claim keys whose header vs summed lines differ beyond
   the tolerance.

   Params:
     model            : injected by dbt (the header relation).
     column_name      : injected by dbt (the header total column).
     claim_key        : key column joining header to lines (default 'claim_sk').
     line_model       : ref()/source() string OR relation of the line model
                        (e.g. "ref('silver_claim_line')").
     line_amount_col  : amount column on the line model (default 'line_amount').
     line_claim_key   : key column on the line model (default = claim_key).
     tolerance        : absolute tolerance in currency units (default 0.01).

   Usage (in schema.yml on the header model):
       columns:
         - name: total_charge_amount
           tests:
             - claim_header_line_reconciliation:
                 claim_key: claim_sk
                 line_model: "ref('silver_claim_line')"
                 line_amount_col: charge_amount
                 tolerance: 0.01
   ============================================================================= #}

{% test claim_header_line_reconciliation(
        model,
        column_name,
        line_model,
        claim_key='claim_sk',
        line_amount_col='line_amount',
        line_claim_key=none,
        tolerance=0.01
    ) %}

{%- set line_claim_key = line_claim_key if line_claim_key is not none else claim_key -%}

with header as (
    select
        {{ claim_key }}    as claim_key,
        {{ column_name }}  as header_amount
    from {{ model }}
),

lines as (
    select
        {{ line_claim_key }}        as claim_key,
        sum({{ line_amount_col }})  as lines_amount
    from {{ line_model }}
    group by 1
)

select
    h.claim_key,
    h.header_amount,
    coalesce(l.lines_amount, 0) as lines_amount,
    abs(h.header_amount - coalesce(l.lines_amount, 0)) as abs_diff
from header h
left join lines l
    on h.claim_key = l.claim_key
-- failing when header and summed lines disagree beyond tolerance
where abs(h.header_amount - coalesce(l.lines_amount, 0)) > {{ tolerance }}

{% endtest %}
