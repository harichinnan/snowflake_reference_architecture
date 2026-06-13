{# =============================================================================
   macros/audit_columns.sql
   snowflake-claims-platform

   Emits the standard set of audit / lineage / SCD column expressions appended
   to silver+ models. Centralizing these guarantees every conformed model
   carries identical provenance columns.

   Params (all optional, sensible defaults):
     source_system   : SQL expr or literal for the originating system.
     batch_id        : SQL expr or literal for the load batch.
     load_id         : SQL expr or literal for the COPY INTO load id.
     pipeline_run_id : SQL expr or literal for the run id (defaults to
                       invocation_id so each dbt run is traceable).
     payload_hash    : SQL expr for the payload hash (default null).
     is_current      : SCD current-flag expr (default TRUE).
     effective_from  : SCD effective-from expr (default current_timestamp()).
     effective_to    : SCD effective-to expr (default null = open).

   Usage (inside a SELECT):
     select
         ...,
         {{ audit_columns(source_system="'SYNTH_CLAIMS_837'",
                          batch_id='b.batch_id',
                          payload_hash='b.payload_hash') }}
     from ...
   ============================================================================= #}

{% macro audit_columns(
        source_system='null',
        batch_id='null',
        load_id='null',
        pipeline_run_id=none,
        payload_hash='null',
        is_current='true',
        effective_from='current_timestamp()',
        effective_to='null'
    ) %}

    {#- Default pipeline_run_id to dbt's invocation_id so runs are traceable
        even when an explicit run id isn't threaded through. -#}
    {%- if pipeline_run_id is none -%}
        {%- set pipeline_run_id = "'" ~ invocation_id ~ "'" -%}
    {%- endif -%}

    current_timestamp()                          as created_at,
    current_timestamp()                          as updated_at,
    {{ source_system }}                          as source_system,
    {{ batch_id }}                               as batch_id,
    {{ load_id }}                                as load_id,
    {{ pipeline_run_id }}                        as pipeline_run_id,
    {{ payload_hash }}                           as payload_hash,
    {{ is_current }}                             as is_current,
    {{ effective_from }}                         as effective_from,
    {{ effective_to }}                           as effective_to

{% endmacro %}
