-- =============================================================================
-- control_semantic_metric_registry.sql
-- CONTROL :: queryable projection of the semantic metric registry.
--
-- DCM Domain J (Semantic). Surfaces CONTROL.SEMANTIC_METRIC_REGISTRY (the
-- governed catalog of certified business metrics) so Cortex Analyst, BI, and
-- reviewers share one definition per metric: the business definition, the
-- canonical calculation SQL, the grain, the owner, certification status, the
-- backing GOLD source model, the dimensions a metric may be sliced by, and any
-- default filters that must always apply.
--
-- NOTE: if the registry physically lives in SEMANTIC.METRIC_REGISTRY rather
-- than CONTROL.SEMANTIC_METRIC_REGISTRY, point the source() (or the fully
-- qualified reference) below at that relation instead.
-- =============================================================================

{{ config(materialized='table', tags=['control', 'dcm_j_semantic']) }}

with registry as (

    select *
    from {{ source('control', 'semantic_metric_registry') }}

)

select
    metric_name,
    business_definition,        -- plain-language meaning (single source of truth)
    calculation_sql,            -- canonical SQL expression for the metric
    grain,                      -- grain the metric is defined at
    owner,                      -- accountable owner / steward
    certified_status,           -- CERTIFIED / DRAFT / DEPRECATED
    source_model,               -- backing GOLD/SEMANTIC model
    allowed_dimensions,         -- ARRAY/VARIANT of valid slicing dimensions
    default_filters,            -- filters always applied (e.g. exclude voids)
    -- Convenience flag for governance gating on consumers (e.g. MCP).
    (upper(certified_status) = 'CERTIFIED') as is_certified
from registry
