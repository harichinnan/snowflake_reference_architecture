-- =============================================================================
-- fact_pharmacy_claim.sql
-- Layer: SILVER_DIMENSIONAL (transactional fact)
--
-- GRAIN: one row per pharmacy (Rx) claim -- one fill event. Pharmacy claims are
--        flat (no separate line grain in this synthetic model), so the claim is
--        the fact row.
--
-- Keys
--   fact_pharmacy_claim_sk = hash(pharmacy_claim_id)
--   Natural key RETAINED: pharmacy_claim_id.
--   FKs: patient_sk, provider_sk (prescriber), pharmacy_provider_sk (pharmacy),
--        plan_sk, date_sk (fill_date).
--
-- Measures (additive): charge_amount, allowed_amount, paid_amount,
--   patient_pay, days_supply, quantity.
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags = ['silver', 'dimensional', 'fact', 'pharmacy']
  )
}}

with rx as (

    select *
    from {{ ref('pharmacy_claim') }}

),

final as (

    select
        -- ---- surrogate key --------------------------------------------------
        {{ generate_surrogate_key(['pharmacy_claim_id']) }}    as fact_pharmacy_claim_sk,

        -- ---- dimension FKs --------------------------------------------------
        {{ generate_surrogate_key(['member_id']) }}            as patient_sk,
        {{ generate_surrogate_key(['prescriber_npi']) }}       as provider_sk,
        {{ generate_surrogate_key(['pharmacy_npi']) }}         as pharmacy_provider_sk,
        -- NOTE: silver_canonical.pharmacy_claim carries NO plan_id / payer_id
        -- (pharmacy events are not linked to medical plan/payer in this model),
        -- so the plan/payer dimension keys are NULL here rather than fabricated.
        -- They could later be derived through the member's eligibility_span by
        -- fill_date if pharmacy-to-plan attribution is required.
        cast(null as string)                                   as plan_sk,
        cast(null as string)                                   as payer_sk,
        cast(to_char(fill_date, 'YYYYMMDD') as integer)        as date_sk,

        -- ---- retained natural keys -----------------------------------------
        pharmacy_claim_id,
        member_id,
        prescriber_npi,
        pharmacy_npi,
        -- plan_id / payer_id are not available on pharmacy_claim (see note above).
        ndc,                                                   -- drug identifier (NDC)

        -- ---- attributes -----------------------------------------------------
        fill_date,

        -- ---- additive measures ---------------------------------------------
        coalesce(charge_amount, 0)         as charge_amount,
        coalesce(allowed_amount, 0)        as allowed_amount,
        coalesce(paid_amount, 0)           as paid_amount,
        coalesce(patient_pay_amount, 0)    as patient_pay,
        coalesce(days_supply, 0)           as days_supply,
        coalesce(quantity_dispensed, 0)    as quantity,

        -- ---- derived --------------------------------------------------------
        date_trunc('month', fill_date)::date as claim_month,
        year(fill_date)                      as service_year,

        -- ---- audit ----------------------------------------------------------
        {{ audit_columns() }}

    from rx

)

select * from final
