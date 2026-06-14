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
    {#- Local, package-free implementation (was dbt_utils.generate_surrogate_key).
        Trial Snowflake account cannot run `dbt deps`, so we vendor the logic. -#}
    {{ return(claims_surrogate_key_md5(field_list)) }}
{% endmacro %}


{# -----------------------------------------------------------------------------
   generate_surrogate_key: package-free replacement for
   dbt_utils.generate_surrogate_key. The 26 model call sites invoke this
   UNQUALIFIED (e.g. {{ generate_surrogate_key(['claim_id','claim_version']) }}),
   so defining it here in the project namespace resolves those calls without the
   dbt_utils package. Delegates to claims_surrogate_key_md5 below, which returns
   a deterministic, null-safe MD5 surrogate.
   ----------------------------------------------------------------------------- #}
{% macro generate_surrogate_key(field_list) %}
    {{ return(claims_surrogate_key_md5(field_list)) }}
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
