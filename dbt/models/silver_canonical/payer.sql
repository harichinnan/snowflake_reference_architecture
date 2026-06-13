-- =============================================================================
-- payer.sql
-- Layer: SILVER_CANONICAL (canonical entity)
-- Grain: one row per payer_id.
--
-- Purpose
--   Distinct payer master, assembled from the payer_ids that actually appear on
--   claims and eligibility events (the platform has no standalone payer feed --
--   payers are conformed from usage). A synthetic payer_name is generated, and
--   payer_category (MEDICARE / MEDICAID / COMMERCIAL) is derived from the
--   plan_type seed mapping.
--
-- Keys
--   payer_id   -- natural key (preserved).
--   payer_sk   -- surrogate over payer_id.
-- =============================================================================

{{
  config(
    materialized   = 'incremental',
    incremental_strategy = 'merge',
    unique_key     = 'payer_sk',
    on_schema_change = 'append_new_columns',
    tags           = ['silver', 'canonical', 'entity', 'payer']
  )
}}

with from_claims as (
    select distinct payer_id, plan_id
    from {{ ref('int_current_valid_claims') }}
    where payer_id is not null
),

from_elig as (
    select distinct
        {{ variant_value('payload', 'payer_id', 'string') }} as payer_id,
        {{ variant_value('payload', 'plan_type', 'string') }} as plan_type
    from {{ ref('br_raw_eligibility_event') }}
    where record_status = 'VALID'
      and {{ variant_value('payload', 'payer_id', 'string') }} is not null
),

-- Distinct payers across both sources.
payers as (
    select payer_id from from_claims
    union
    select payer_id from from_elig
),

-- Resolve a representative plan_type per payer (from eligibility, the typed
-- source) to derive the category. Most common plan_type wins.
payer_plan_type as (
    select
        payer_id,
        max_by(plan_type, cnt) as plan_type
    from (
        select payer_id, plan_type, count(*) as cnt
        from from_elig
        where plan_type is not null
        group by payer_id, plan_type
    )
    group by payer_id
),

-- Map plan_type -> category via the reference seed. The seed is expected to
-- carry plan_type + payer_category columns.
plan_type_ref as (
    select
        plan_type,
        payer_category
    from {{ ref('ref_plan_type') }}
)

select
    p.payer_id,

    -- Synthetic but stable, human-readable payer name.
    'Payer ' || p.payer_id                                            as payer_name,

    -- Category from the seed; default COMMERCIAL when unmapped.
    coalesce(ptr.payer_category, 'COMMERCIAL')                        as payer_category,
    ppt.plan_type                                                     as representative_plan_type,

    -- ---- surrogate + audit --------------------------------------------------
    {{ generate_surrogate_key(['p.payer_id']) }}                      as payer_sk,
    true                                                              as is_current,
    current_timestamp()                                              as effective_from,
    cast(null as timestamp_ntz)                                      as effective_to,

    'CONFORMED'                                                      as source_system,
    cast(null as string)                                            as batch_id,
    cast(null as string)                                            as load_id,
    cast(null as string)                                            as pipeline_run_id,
    cast(null as string)                                            as payload_hash,
    current_timestamp()                                             as created_at,
    current_timestamp()                                             as updated_at

from payers p
left join payer_plan_type ppt
    on p.payer_id = ppt.payer_id
left join plan_type_ref ptr
    on ppt.plan_type = ptr.plan_type
