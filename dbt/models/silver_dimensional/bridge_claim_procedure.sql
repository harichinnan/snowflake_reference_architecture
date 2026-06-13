-- =============================================================================
-- bridge_claim_procedure.sql
-- Layer: SILVER_DIMENSIONAL (bridge / factless relationship)
--
-- GRAIN: one row per (claim, procedure position). Resolves the many-to-many
--        relationship between a claim header and the procedure dimension.
--
-- Keys
--   bridge_claim_procedure_sk = hash(claim_id, claim_version, procedure_position)
--   FKs: claim_header_sk, procedure_sk -> dim_procedure.
--
-- Only procedures for the CURRENT valid claim version are included.
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags = ['silver', 'dimensional', 'bridge', 'procedure']
  )
}}

with current_claims as (

    select claim_id, claim_version
    from {{ ref('int_current_valid_claims') }}

),

claim_proc as (

    select p.*
    from {{ ref('claim_procedure') }} p
    inner join current_claims c
        on p.claim_id = c.claim_id
       and p.claim_version = c.claim_version

),

final as (

    select
        -- ---- surrogate key --------------------------------------------------
        {{ generate_surrogate_key(['claim_id', 'claim_version', 'procedure_position']) }}
                                                               as bridge_claim_procedure_sk,

        -- ---- FKs ------------------------------------------------------------
        {{ generate_surrogate_key(['claim_id']) }}             as claim_header_sk,
        {{ generate_surrogate_key(['procedure_code']) }}       as procedure_sk,

        -- ---- retained natural keys -----------------------------------------
        claim_id,
        claim_version,
        procedure_code,

        -- ---- relationship attributes ---------------------------------------
        procedure_position,
        procedure_date,

        -- ---- audit ----------------------------------------------------------
        {{ audit_columns() }}

    from claim_proc

)

select * from final
