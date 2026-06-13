{# =============================================================================
   macros/quarantine_insert.sql
   snowflake-claims-platform

   Emits an INSERT INTO AUDIT.QUARANTINE_RECORD for rows that fail validation.
   Designed to be used either:
     (a) as a post-hook on a model:
           +post-hook: "{{ quarantine_insert('silver_canonical.claim_event',
                          failing_rows_select) }}"
     (b) inline in an operation / run-operation.

   The macro builds a statement that selects the failing rows (caller-supplied
   SELECT that must expose: natural_key, payload, quarantine_reason) and inserts
   them with generated quarantine_id, source_table, pipeline_run_id and
   quarantined_at metadata.

   Params:
     source_table        : string identifying the originating object (stored as-is).
     failing_rows_select : a full SELECT statement string returning at least
                           (natural_key, payload, quarantine_reason).
     pipeline_run_id     : optional run id literal/expr (default invocation_id).

   Notes:
     - We use object column list explicitly so column order is robust.
     - quarantine_id derived via uuid_string() for uniqueness.
     - Wrapped so dbt only runs it when execute is true (skips during parse).
   ============================================================================= #}

{% macro quarantine_insert(source_table, failing_rows_select, pipeline_run_id=none) %}

    {%- set aud_db   = env_var('DBT_SNOWFLAKE_DATABASE', target.database) -%}
    {%- set aud_sch  = var('audit_schema', 'AUDIT') -%}
    {%- set q_tbl    = aud_db ~ '.' ~ aud_sch ~ '.' ~ var('audit_quarantine_record', 'QUARANTINE_RECORD') -%}

    {%- if pipeline_run_id is none -%}
        {%- set pipeline_run_id = "'" ~ invocation_id ~ "'" -%}
    {%- endif -%}

    insert into {{ q_tbl }} (
        quarantine_id,
        source_table,
        natural_key,
        payload,
        quarantine_reason,
        pipeline_run_id,
        quarantined_at
    )
    select
        uuid_string()                       as quarantine_id,
        '{{ source_table }}'                as source_table,
        failing.natural_key                 as natural_key,
        failing.payload                     as payload,
        failing.quarantine_reason           as quarantine_reason,
        {{ pipeline_run_id }}               as pipeline_run_id,
        current_timestamp()                 as quarantined_at
    from (
        {{ failing_rows_select }}
    ) as failing

{% endmacro %}
