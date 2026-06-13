{# =============================================================================
   macros/control_watermark_update.sql
   snowflake-claims-platform

   Advances CONTROL.WATERMARK_STATE for a pipeline after a successful build.
   Sets prior_successful_watermark = (old) last_successful_watermark and
   last_successful_watermark = max(business_event_ts) observed in the model.

   Use as a post-hook so the watermark only advances once the model materialized
   successfully:
       config(
         post_hook="{{ control_watermark_update('claim_event',
                       this, 'business_event_ts') }}"
       )

   The MERGE upserts the pipeline row: inserts on first run, updates thereafter.
   We compute the new watermark from the just-built relation ({{ this }} by
   default) so it reflects exactly what landed.

   Params:
     pipeline_name : pipeline key to upsert.
     relation      : relation to read max(ts) from (default this).
     event_ts_col  : timestamp column to take max() of (default 'business_event_ts').

   Idempotent: re-running with the same data yields the same max, so the
   watermark never regresses (greatest() guard).
   ============================================================================= #}

{# Tolerant signature: accepts alias kwargs used by call sites.
   - `watermark_column` is an alias for `event_ts_col`.
   - `this_relation` is an alias for `relation`.
   - Jinja's implicit `kwargs` absorbs any other drifted kwarg names. #}
{% macro control_watermark_update(pipeline_name, relation=none, event_ts_col='business_event_ts', watermark_column=none, this_relation=none) %}

    {%- set event_ts_col = watermark_column if watermark_column is not none else event_ts_col -%}
    {%- set relation     = this_relation   if this_relation   is not none else relation -%}

    {%- set wm_db      = env_var('DBT_SNOWFLAKE_DATABASE', target.database) -%}
    {%- set ctl_schema = var('control_schema', 'CONTROL') -%}
    {%- set wm_tbl     = wm_db ~ '.' ~ ctl_schema ~ '.' ~ var('control_watermark_state', 'WATERMARK_STATE') -%}
    {%- set rel        = relation if relation is not none else this -%}

    merge into {{ wm_tbl }} as tgt
    using (
        select
            '{{ pipeline_name }}'        as pipeline_name,
            max({{ event_ts_col }})      as new_watermark
        from {{ rel }}
    ) as src
       on tgt.pipeline_name = src.pipeline_name

    when matched then update set
        -- carry the old high-watermark into prior_* for replay/audit
        tgt.prior_successful_watermark = tgt.last_successful_watermark,
        -- never regress: keep the greater of existing vs newly observed
        tgt.last_successful_watermark  = greatest(
            coalesce(tgt.last_successful_watermark, '1900-01-01'::timestamp_ntz),
            coalesce(src.new_watermark,             '1900-01-01'::timestamp_ntz)
        ),
        tgt.updated_at = current_timestamp()

    when not matched then insert (
        pipeline_name,
        last_successful_watermark,
        prior_successful_watermark,
        updated_at
    ) values (
        src.pipeline_name,
        src.new_watermark,
        null,
        current_timestamp()
    )

{% endmacro %}
