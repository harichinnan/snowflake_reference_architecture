-- =============================================================================
-- plan.sql
-- Layer: SILVER_CANONICAL (canonical entity)
-- Grain: one row per plan_id.
--
-- Purpose
--   Distinct plan master, conformed from claims + eligibility. Each plan rolls
--   up to a payer (payer_id) and carries a plan_type plus the descriptive
--   plan_type_name resolved from the ref_plan_type seed.
--
-- Keys
--   plan_id  -- natural key (preserved).
--   plan_sk  -- surrogate over plan_id.
-- =============================================================================

{{
  config(
    materialized   = 'incremental',
    incremental_strategy = 'merge',
    unique_key     = 'plan_sk',
    on_schema_change = 'append_new_columns',
    tags           = ['silver', 'canonical', 'entity', 'plan']
  )
}}

with from_elig as (
    select
        {{ variant_value('payload', 'plan_id', 'string') }}   as plan_id,
        {{ variant_value('payload', 'payer_id', 'string') }}  as payer_id,
        {{ variant_value('payload', 'plan_type', 'string') }} as plan_type,
        business_event_ts
    from {{ ref('br_raw_eligibility_event') }}
    where record_status = 'VALID'
      and {{ variant_value('payload', 'plan_id', 'string') }} is not null
),

from_claims as (
    select distinct
        plan_id,
        payer_id,
        claim_type as plan_type,        -- claims don't carry plan_type; placeholder NULL-safe below
        cast(null as timestamp_ntz) as business_event_ts
    from {{ ref('int_current_valid_claims') }}
    where plan_id is not null
),

-- Eligibility is the authoritative source of plan_type; prefer it. Claims only
-- backfill plans that never appeared in eligibility (payer linkage only).
elig_current as (
    select *
    from from_elig
    qualify row_number() over (
        partition by plan_id
        order by business_event_ts desc nulls last
    ) = 1
),

plan_keys as (
    select plan_id from elig_current
    union
    select plan_id from from_claims
),

resolved as (
    select
        k.plan_id,
        coalesce(e.payer_id, c.payer_id)                              as payer_id,
        e.plan_type                                                   as plan_type,
        coalesce(e.business_event_ts, current_timestamp())            as effective_from
    from plan_keys k
    left join elig_current e on k.plan_id = e.plan_id
    left join (
        select plan_id, max(payer_id) as payer_id
        from from_claims group by plan_id
    ) c on k.plan_id = c.plan_id
),

plan_type_ref as (
    -- ref_plan_type join key is plan_type_code (the plan_type value carried on
    -- the eligibility payload maps to plan_type_code).
    select plan_type_code, plan_type_name
    from {{ ref('ref_plan_type') }}
)

select
    r.plan_id,
    r.payer_id,
    r.plan_type,
    ptr.plan_type_name,

    -- ---- surrogate + audit --------------------------------------------------
    {{ generate_surrogate_key(['r.plan_id']) }}                       as plan_sk,
    true                                                              as is_current,
    r.effective_from                                                 as effective_from,
    cast(null as timestamp_ntz)                                      as effective_to,

    'CONFORMED'                                                      as source_system,
    cast(null as string)                                            as batch_id,
    cast(null as string)                                            as load_id,
    cast(null as string)                                            as pipeline_run_id,
    cast(null as string)                                            as payload_hash,
    current_timestamp()                                             as created_at,
    current_timestamp()                                             as updated_at

from resolved r
left join plan_type_ref ptr
    on r.plan_type = ptr.plan_type_code
