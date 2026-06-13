-- =============================================================================
-- control_data_contract.sql
-- CONTROL :: queryable projection of the source data contracts.
--
-- DCM Domain A (Source). Surfaces CONTROL.DATA_CONTRACT joined to its current
-- schema version so consumers can see, per (source_system, object_name), the
-- required fields, primary business keys, expected grain, and whether the
-- contract row is the current/effective version.
--
-- Materialized as a table in CONTROL (see dbt_project.yml control config).
-- =============================================================================

{{ config(materialized='table', tags=['control', 'dcm_a_source']) }}

with contract as (

    select *
    from {{ source('control', 'data_contract') }}

),

-- Determine the current schema version per contract object. The contract table
-- may carry multiple versions; the latest effective (non-future, highest
-- version) row is treated as current.
ranked as (

    select
        *,
        row_number() over (
            partition by source_system, object_name
            order by
                coalesce(schema_version, 0) desc,
                coalesce(effective_from, to_timestamp_ntz('1900-01-01')) desc
        ) as version_rank
    from contract

)

select
    source_system,
    object_name,
    schema_version,
    -- One row per (source_system, object_name): the contract terms.
    required_fields,            -- ARRAY/VARIANT of mandatory fields (DCM A)
    primary_business_keys,      -- ARRAY/VARIANT of natural-key fields (DCM A/D)
    expected_grain,             -- declared grain of the object (DCM A)
    effective_from,
    effective_to,
    -- is_current: the highest effective version is the active contract.
    (version_rank = 1) as is_current
from ranked
