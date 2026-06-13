{# =============================================================================
   macros/claim_business_keys.sql
   snowflake-claims-platform

   Builds deterministic natural/business-key hashes for the core claims
   entities. Keys are MD5 over the normalized, null-safe, pipe-delimited key
   fields (delegating to claims_surrogate_key for consistency with dbt_utils).

   Provided helpers:
     claim_business_key(...)         -> claim_id|claim_version|member_id|payer_id
     pharmacy_claim_business_key(...)-> rx_number|ndc|fill_date|member_id
     eligibility_business_key(...)   -> member_id|plan_id|coverage_effective_date
     provider_business_key(...)      -> provider_npi
     adjudication_business_key(...)  -> claim_id|claim_version|payer_claim_control_number

   Each accepts column-name (or SQL-expression) strings so it can be called over
   parsed VARIANT values or already-typed columns.

   Usage:
       {{ claim_business_key('claim_id','claim_version','member_id','payer_id') }} as claim_natural_key
   ============================================================================= #}

{% macro claim_business_key(claim_id, claim_version, member_id, payer_id) %}
    {{ claims_surrogate_key([claim_id, claim_version, member_id, payer_id]) }}
{% endmacro %}


{% macro pharmacy_claim_business_key(rx_number, ndc, fill_date, member_id) %}
    {{ claims_surrogate_key([rx_number, ndc, fill_date, member_id]) }}
{% endmacro %}


{% macro eligibility_business_key(member_id, plan_id, coverage_effective_date) %}
    {{ claims_surrogate_key([member_id, plan_id, coverage_effective_date]) }}
{% endmacro %}


{% macro provider_business_key(provider_npi) %}
    {{ claims_surrogate_key([provider_npi]) }}
{% endmacro %}


{% macro adjudication_business_key(claim_id, claim_version, payer_claim_control_number) %}
    {{ claims_surrogate_key([claim_id, claim_version, payer_claim_control_number]) }}
{% endmacro %}
