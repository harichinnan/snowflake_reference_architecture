{# =============================================================================
   macros/apply_lookback_window.sql
   snowflake-claims-platform

   Returns a `dateadd('day', -<lookback_days>, <watermark>)` SQL expression --
   the lower bound of the incremental window. Useful when you want the bound as
   a standalone expression (e.g. in a CTE, join predicate, or for logging)
   rather than the full WHERE predicate produced by incremental_watermark_filter.

   lookback_days resolution order:
     1. explicit `lookback_days` param (literal int), if provided;
     2. else a correlated subquery against CONTROL.PIPELINE_CONFIG for the
        pipeline (works without run_query);
     3. else var('lookback_default_days').

   Params:
     watermark_expr : SQL expression for the watermark timestamp. Defaults to a
                      subquery reading CONTROL.WATERMARK_STATE for pipeline_name.
     pipeline_name  : pipeline key (required if reading config/watermark).
     lookback_days  : optional literal override (skips the config subquery).

   Usage:
       -- explicit lookback, explicit watermark:
       {{ apply_lookback_window(watermark_expr='max_seen_ts', lookback_days=7) }}

       -- config-driven:
       {{ apply_lookback_window(pipeline_name='claim_event') }}
   ============================================================================= #}

{% macro apply_lookback_window(watermark_expr=none, pipeline_name=none, lookback_days=none) %}

    {%- set wm_db      = env_var('DBT_SNOWFLAKE_DATABASE', target.database) -%}
    {%- set ctl_schema = var('control_schema', 'CONTROL') -%}
    {%- set wm_tbl     = ctl_schema ~ '.' ~ var('control_watermark_state', 'WATERMARK_STATE') -%}
    {%- set cfg_tbl    = ctl_schema ~ '.' ~ var('control_pipeline_config', 'PIPELINE_CONFIG') -%}
    {%- set default_lb = var('lookback_default_days', 3) -%}

    {#- Resolve the watermark expression: explicit, else subquery, else epoch. -#}
    {%- if watermark_expr is none -%}
        {%- if pipeline_name is none -%}
            {{ exceptions.raise_compiler_error("apply_lookback_window: provide watermark_expr or pipeline_name") }}
        {%- endif -%}
        {%- set watermark_expr -%}
            coalesce(
                (
                    select ws.last_successful_watermark
                    from {{ wm_db }}.{{ wm_tbl }} as ws
                    where ws.pipeline_name = '{{ pipeline_name }}'
                ),
                '1900-01-01'::timestamp_ntz
            )
        {%- endset -%}
    {%- endif -%}

    {#- Resolve lookback: literal override > config subquery > default. -#}
    {%- if lookback_days is not none -%}
        {%- set lb_expr = lookback_days -%}
    {%- elif pipeline_name is not none -%}
        {%- set lb_expr -%}
            coalesce(
                (
                    select cfg.lookback_days
                    from {{ wm_db }}.{{ cfg_tbl }} as cfg
                    where cfg.pipeline_name = '{{ pipeline_name }}'
                ),
                {{ default_lb }}
            )
        {%- endset -%}
    {%- else -%}
        {%- set lb_expr = default_lb -%}
    {%- endif -%}

    dateadd('day', -1 * ({{ lb_expr }}), {{ watermark_expr }})

{% endmacro %}
