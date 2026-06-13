{# =============================================================================
   macros/incremental_watermark_filter.sql
   snowflake-claims-platform

   Emits an incremental WHERE predicate that selects rows at/after the stored
   high-watermark minus a configurable lookback window (to recapture late /
   corrected facts). On the first run (or when no watermark/config row exists),
   it emits TRUE so the full history is loaded.

   Predicate shape (simplified):
       <event_ts_column> >= dateadd(
           'day',
           -<lookback_days>,
           coalesce(<last_successful_watermark>, '1900-01-01')
       )

   DEFAULT IMPLEMENTATION (no run_query): correlated scalar subqueries against
   CONTROL.WATERMARK_STATE and CONTROL.PIPELINE_CONFIG. This compiles and runs
   without a database round-trip at parse time and keeps the watermark logic
   inside the warehouse (good for idempotent re-runs).

   Params:
     pipeline_name    : logical pipeline key (matches CONTROL rows).
     event_ts_column  : column in this model holding the business event ts.
     default_lookback : fallback lookback days if PIPELINE_CONFIG has no row
                        (defaults to var lookback_default_days).

   Usage:
       where {{ incremental_watermark_filter('claim_event', 'business_event_ts') }}

   ---------------------------------------------------------------------------
   ALTERNATIVE (run_query) is shown commented at the bottom: fetch the watermark
   at compile time and inline a literal. Prefer the subquery form unless you
   need the literal value for partition pruning hints.
   ============================================================================= #}

{# Tolerant signature: accepts the drifted call shapes used across models.
   - `watermark_column` is an alias for `event_ts_column`.
   - All args default to none so call sites may omit them.
   - Single-positional form `incremental_watermark_filter('ingest_ts')` (used in
     silver_canonical) passes only the event-ts column; in that case we treat the
     lone positional as the event-ts column and derive the pipeline_name from the
     current model.
   - Jinja's implicit `kwargs` absorbs any other drifted kwarg names. #}
{% macro incremental_watermark_filter(pipeline_name=none, event_ts_column=none, default_lookback=none, watermark_column=none) %}

    {%- set event_ts_column = watermark_column if watermark_column is not none else event_ts_column -%}

    {#- Single-positional form: the lone arg is the event-ts column, not the
        pipeline name. Reassign and derive pipeline_name from the model id. -#}
    {%- if event_ts_column is none and pipeline_name is not none -%}
        {%- set event_ts_column = pipeline_name -%}
        {%- set pipeline_name = none -%}
    {%- endif -%}
    {%- if pipeline_name is none -%}
        {%- set pipeline_name = this.identifier if this is defined else model.name -%}
    {%- endif -%}

    {%- if default_lookback is none -%}
        {%- set default_lookback = var('lookback_default_days', 3) -%}
    {%- endif -%}

    {#- Only constrain on incremental runs. Full refresh / first build => TRUE. -#}
    {%- if is_incremental() -%}

        {%- set wm_db      = env_var('DBT_SNOWFLAKE_DATABASE', target.database) -%}
        {%- set ctl_schema = var('control_schema', 'CONTROL') -%}
        {%- set wm_tbl     = ctl_schema ~ '.' ~ var('control_watermark_state', 'WATERMARK_STATE') -%}
        {%- set cfg_tbl    = ctl_schema ~ '.' ~ var('control_pipeline_config', 'PIPELINE_CONFIG') -%}

        {{ event_ts_column }} >= dateadd(
            'day',
            -1 * coalesce(
                (
                    select cfg.lookback_days
                    from {{ wm_db }}.{{ cfg_tbl }} as cfg
                    where cfg.pipeline_name = '{{ pipeline_name }}'
                ),
                {{ default_lookback }}
            ),
            coalesce(
                (
                    select ws.last_successful_watermark
                    from {{ wm_db }}.{{ wm_tbl }} as ws
                    where ws.pipeline_name = '{{ pipeline_name }}'
                ),
                '1900-01-01'::timestamp_ntz   -- no watermark yet => load all history
            )
        )

    {%- else -%}
        true
    {%- endif -%}

{% endmacro %}


{# -----------------------------------------------------------------------------
   ALTERNATIVE run_query implementation (compile-time literal). Uncomment to use.

{% macro incremental_watermark_filter_runquery(pipeline_name, event_ts_column, default_lookback=none) %}
    {%- if default_lookback is none -%}
        {%- set default_lookback = var('lookback_default_days', 3) -%}
    {%- endif -%}
    {%- if is_incremental() and execute -%}
        {%- set wm_db = env_var('DBT_SNOWFLAKE_DATABASE', target.database) -%}
        {%- set ctl = var('control_schema', 'CONTROL') -%}
        {%- set q -%}
            select
                coalesce(ws.last_successful_watermark, '1900-01-01'::timestamp_ntz) as wm,
                coalesce(cfg.lookback_days, {{ default_lookback }})                 as lb
            from (select 1 as j) d
            left join {{ wm_db }}.{{ ctl }}.{{ var('control_watermark_state','WATERMARK_STATE') }} ws
                   on ws.pipeline_name = '{{ pipeline_name }}'
            left join {{ wm_db }}.{{ ctl }}.{{ var('control_pipeline_config','PIPELINE_CONFIG') }} cfg
                   on cfg.pipeline_name = '{{ pipeline_name }}'
        {%- endset -%}
        {%- set res = run_query(q) -%}
        {%- set wm = res.columns[0].values()[0] -%}
        {%- set lb = res.columns[1].values()[0] -%}
        {{ event_ts_column }} >= dateadd('day', -{{ lb }}, '{{ wm }}'::timestamp_ntz)
    {%- else -%}
        true
    {%- endif -%}
{% endmacro %}
   ----------------------------------------------------------------------------- #}
