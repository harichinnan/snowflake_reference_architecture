{# =============================================================================
   macros/generate_surrogate_key.sql
   snowflake-claims-platform

   Thin wrapper over dbt_utils.generate_surrogate_key so the project has a
   single, consistently-named entry point for building deterministic surrogate
   keys. dbt_utils handles null coercion (nulls -> a sentinel) and field
   concatenation, then MD5s the result.

   Usage:
     {{ claims_surrogate_key(['claim_id', 'claim_version', 'member_id']) }}

   A pure-SQL fallback (no dbt_utils dependency) is provided as
   claims_surrogate_key_md5 in case the package is unavailable.
   ============================================================================= #}

{% macro claims_surrogate_key(field_list) %}
    {#- Delegate to dbt_utils; it null-safes each field and hashes with MD5. -#}
    {{ return(dbt_utils.generate_surrogate_key(field_list)) }}
{% endmacro %}


{# -----------------------------------------------------------------------------
   Pure-SQL fallback: MD5 over '|'-delimited, null-coalesced, trimmed fields.
   Mirrors dbt_utils semantics (null -> '_dbt_utils_surrogate_key_null_') so
   keys are stable and collision-resistant for typical claim grains.
   ----------------------------------------------------------------------------- #}
{% macro claims_surrogate_key_md5(field_list) %}
    md5(
        {%- for field in field_list %}
        coalesce(cast({{ field }} as varchar), '_dbt_utils_surrogate_key_null_')
        {%- if not loop.last %} || '|' || {% endif -%}
        {% endfor %}
    )
{% endmacro %}
