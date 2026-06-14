-- =============================================================================
-- gold_claim_denial_summary.sql
-- Layer: GOLD (CERTIFIED semantic data product)
--
-- Business question: "What is our denial rate by payer/plan/status, and what are
-- the top denial reasons?" The certified denial product.
--
-- GRAIN: one row per (payer, plan, claim_status, denial_reason, month).
--   Rows with denial_reason = NULL/'NONE' represent non-denied claims for that
--   slice, so denial_rate = denied / total computes cleanly per partition.
--
-- Certified metrics: denial_rate (denied_claims / total_claims),
--   denied_paid_impact. denial_reason resolved via ref_denial_reason and
--   claim_status via ref_claim_status. See SEMANTIC_METRIC_REGISTRY: denial_rate.
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags = ['gold', 'mart', 'semantic', 'certified', 'denial']
  )
}}

with base as (

    select *
    from {{ ref('gold_claims_semantic_base') }}

),

denial_reason_ref as (
    -- ref_denial_reason carries denial_reason_name (not _description).
    select denial_reason_code, denial_reason_name as denial_reason_description
    from {{ ref('ref_denial_reason') }}
),

status_ref as (
    -- ref_claim_status keys on status_code / status_name.
    select status_code as claim_status_code, status_name as claim_status_description
    from {{ ref('ref_claim_status') }}
),

enriched as (

    select
        b.payer_sk,
        b.plan_sk,
        b.payer_name,
        b.payer_type,
        b.plan_type,
        b.claim_month,
        b.claim_status,
        coalesce(sr.claim_status_description, b.claim_status) as claim_status_description,
        coalesce(b.denial_reason_code, 'NONE')               as denial_reason_code,
        coalesce(dr.denial_reason_description,
                 case when b.denial_flag then 'Unspecified' else 'Not Denied' end)
                                                             as denial_reason,
        b.denial_flag,
        b.claim_id,
        b.paid_amount,
        b.allowed_amount
    from base b
    left join denial_reason_ref dr on b.denial_reason_code = dr.denial_reason_code
    left join status_ref sr        on b.claim_status       = sr.claim_status_code

),

final as (

    select
        payer_sk,
        plan_sk,
        payer_name,
        payer_type,
        plan_type,
        claim_month,
        claim_status,
        claim_status_description,
        denial_reason_code,
        denial_reason,

        -- ---- certified denial metrics --------------------------------------
        count(distinct claim_id)                              as total_claims,
        count(distinct case when denial_flag then claim_id end) as denied_claims,
        case when count(distinct claim_id) > 0
             then count(distinct case when denial_flag then claim_id end)::float
                  / count(distinct claim_id)
             else 0 end                                       as denial_rate,

        -- paid impact: allowed that was withheld on denied lines (proxy).
        sum(case when denial_flag then allowed_amount - paid_amount else 0 end)
                                                              as denied_paid_impact

    from enriched
    group by 1,2,3,4,5,6,7,8,9,10

)

select * from final
