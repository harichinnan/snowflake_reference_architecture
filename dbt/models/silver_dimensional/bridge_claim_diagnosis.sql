-- =============================================================================
-- bridge_claim_diagnosis.sql
-- Layer: SILVER_DIMENSIONAL (bridge / factless relationship)
--
-- GRAIN: one row per (claim, diagnosis position). Resolves the many-to-many
--        relationship between a claim header and the diagnosis dimension -- a
--        claim can carry several diagnoses, and a diagnosis code appears on
--        many claims.
--
-- Keys
--   bridge_claim_diagnosis_sk = hash(claim_id, claim_version, diagnosis_position)
--   FKs: claim_header_sk -> fact_claim_line.claim_header_sk / dim,
--        diagnosis_sk    -> dim_diagnosis.
--
-- Only diagnoses for the CURRENT valid claim version are included so the bridge
-- aligns with fact_claim_line's current-truth grain.
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags = ['silver', 'dimensional', 'bridge', 'diagnosis']
  )
}}

with current_claims as (

    select claim_id, claim_version
    from {{ ref('int_current_valid_claims') }}

),

claim_dx as (

    select d.*
    from {{ ref('claim_diagnosis') }} d
    inner join current_claims c
        on d.claim_id = c.claim_id
       and d.claim_version = c.claim_version

),

final as (

    select
        -- ---- surrogate key --------------------------------------------------
        {{ generate_surrogate_key(['claim_id', 'claim_version', 'diagnosis_position']) }}
                                                               as bridge_claim_diagnosis_sk,

        -- ---- FKs ------------------------------------------------------------
        {{ generate_surrogate_key(['claim_id']) }}             as claim_header_sk,
        {{ generate_surrogate_key(['diagnosis_code']) }}       as diagnosis_sk,

        -- ---- retained natural keys -----------------------------------------
        claim_id,
        claim_version,
        diagnosis_code,

        -- ---- relationship attributes ---------------------------------------
        diagnosis_position,
        diagnosis_type,                                        -- e.g. principal/secondary/admitting
        present_on_admission,
        case when diagnosis_position = 1 then true else false end as is_primary,

        -- ---- audit ----------------------------------------------------------
        {{ audit_columns() }}

    from claim_dx

)

select * from final
