-- =============================================================================
-- generate_schema_name.sql
-- -----------------------------------------------------------------------------
-- Override dbt's default schema-naming so that the per-directory `+schema`
-- values in dbt_project.yml (RAW / CONTROL / BRONZE / SILVER_CANONICAL /
-- SILVER_DIMENSIONAL / GOLD / SEMANTIC) are used VERBATIM.
--
-- Why this matters for this platform:
--   The default dbt behavior concatenates target schema + custom schema, i.e.
--   target `DBT_DEV` + `+schema: BRONZE`  ->  `DBT_DEV_BRONZE`.
--   But every Snowflake setup script, Cortex Search service, semantic view, and
--   CLAIMS_MCP_READER grant references the bare schema names (CLAIMS_DEV.BRONZE,
--   CLAIMS_DEV.GOLD, CLAIMS_DEV.SEMANTIC, ...). Using the custom schema verbatim
--   makes dbt build into exactly those schemas, both for local dbt Core and for
--   dbt Projects on Snowflake (EXECUTE DBT PROJECT).
--
--   Models WITHOUT a `+schema` fall back to the connection's default schema
--   (target.schema), which is only used for incidental objects.
--
-- This is intentionally environment-agnostic: CLAIMS_DEV vs CLAIMS_PROD is
-- selected by the database in the active target/profile, not by schema suffix.
-- =============================================================================
{% macro generate_schema_name(custom_schema_name, node) -%}

    {%- set default_schema = target.schema -%}
    {%- if custom_schema_name is none -%}
        {{ default_schema }}
    {%- else -%}
        {{ custom_schema_name | trim | upper }}
    {%- endif -%}

{%- endmacro %}
