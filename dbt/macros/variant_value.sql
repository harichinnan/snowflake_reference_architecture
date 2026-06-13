{# =============================================================================
   macros/variant_value.sql
   snowflake-claims-platform

   Safely extract and cast a value from a Snowflake VARIANT at a given path.
   Snowflake's `payload:a.b.c` traversal returns NULL for missing paths, and
   try_cast prevents a single bad value from failing the whole load.

   Params:
     payload_col : the VARIANT column (e.g. 'payload', 'b.payload').
     path        : dotted/bracketed VARIANT path WITHOUT leading colon
                   (e.g. 'claim.claim_id', 'lines[0].amount').
     dtype       : target SQL type for try_cast (default 'string').
                   Use 'string','number(18,2)','date','timestamp_ntz','boolean', etc.
     default     : optional SQL literal/expression used when the value is NULL
                   (default 'null').

   Notes:
     - For string extraction we use the `::string` shortcut first then try_cast,
       which trims the VARIANT quoting. For non-string types we go straight to
       try_cast on the variant path.
     - Use safe=True semantics everywhere: bad casts -> NULL -> default.

   Usage:
       {{ variant_value('payload', 'claim.claim_id') }}                       -- string
       {{ variant_value('payload', 'claim.total_charge', 'number(18,2)', '0') }}
       {{ variant_value('payload', 'claim.service_date', 'date') }}
   ============================================================================= #}

{% macro variant_value(payload_col, path, dtype='string', default='null') %}
    {%- set dt = dtype | lower -%}
    coalesce(
        {%- if dt in ['string', 'varchar', 'text', 'char'] -%}
            try_cast({{ payload_col }}:{{ path }}::string as {{ dtype }})
        {%- else -%}
            {#- Cast the VARIANT path text through try_cast for safe coercion. -#}
            try_cast({{ payload_col }}:{{ path }}::string as {{ dtype }})
        {%- endif -%}
        , {{ default }}
    )
{% endmacro %}
