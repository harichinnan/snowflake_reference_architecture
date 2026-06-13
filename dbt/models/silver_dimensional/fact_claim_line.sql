-- =============================================================================
-- fact_claim_line.sql
-- Layer: SILVER_DIMENSIONAL (transactional fact)
--
-- GRAIN (this is the canonical answer to "what is the grain of fact_claim_line?")
--   ONE ROW PER SERVICE LINE OF THE CURRENT VALID VERSION OF A CLAIM.
--   i.e. one row per (claim_id, claim_line_id) for the claim version that
--   int_current_valid_claims marks as current. Superseded / adjusted-away
--   versions are NOT present here -- this fact reflects the as-adjudicated,
--   current financial truth. Adjustment/void/reversal *history* lives in
--   fact_claim_adjustment; this fact carries flags so you can still see that a
--   line's claim was adjusted/reversed without double-counting dollars.
--
-- Keys
--   fact_claim_line_sk = hash(claim_id, claim_line_id, claim_version) -- unique
--                        per row of this fact.
--   Natural keys RETAINED for traceability: claim_id, claim_line_id,
--   claim_version, claim_header_sk.
--   FKs: patient_sk, provider_sk (rendering), payer_sk, plan_sk,
--        date_sk (service_from_date), procedure_sk.
--
-- Measures (additive over the dimensions above)
--   charge_amount, allowed_amount, paid_amount, patient_responsibility (line-
--   allocated), units.
--
-- patient_responsibility allocation
--   Patient responsibility is captured at the header in canonical. We ALLOCATE
--   it down to lines in proportion to line allowed_amount (falling back to an
--   even split when a header has zero total allowed) so the measure stays
--   additive at line grain and reconciles to the header total. The
--   reconciliation is asserted by tests/assert_claim_header_line_totals_reconcile.
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags = ['silver', 'dimensional', 'fact', 'claim_line']
  )
}}

with current_claims as (

    -- Only the current valid version of each claim flows into the fact. This is
    -- what prevents double-counting across the adjustment chain.
    select *
    from {{ ref('int_current_valid_claims') }}

),

header as (

    select *
    from {{ ref('claim_header') }}

),

-- Current header attributes for the current claim versions only.
current_header as (

    select h.*
    from header h
    inner join current_claims c
        on h.claim_id = c.claim_id
       and h.claim_version = c.claim_version

),

lines as (

    select l.*
    from {{ ref('claim_line') }} l
    inner join current_claims c
        on l.claim_id = c.claim_id
       and l.claim_version = c.claim_version

),

-- Header-level totals used to allocate header-only amounts (patient resp) down
-- to the line grain proportionally to line allowed_amount.
header_alloc_basis as (

    select
        claim_id,
        claim_version,
        sum(allowed_amount)        as hdr_line_allowed_total,
        count(*)                   as hdr_line_count
    from lines
    group by 1, 2

),

denial as (

    -- Most recent denial event per claim/line (if any) -> denial flag/reason.
    select
        claim_id,
        claim_version,
        claim_line_id,
        denial_reason_code,
        true as is_denied
    from {{ ref('denial_event') }}
    qualify row_number() over (
        partition by claim_id, claim_version, claim_line_id
        order by event_ts desc
    ) = 1

),

adjustment_chain as (

    -- Per claim, does an adjustment/reversal exist anywhere in its chain?
    select
        root_claim_id                                          as claim_id,
        max(case when adjustment_type is not null then true else false end) as has_adjustment,
        max(coalesce(reversal_indicator, false))              as has_reversal
    from {{ ref('int_claim_adjustment_chain') }}
    group by 1

),

joined as (

    select
        l.claim_id,
        l.claim_version,
        l.claim_line_id,

        -- header attributes
        h.member_id,
        h.payer_id,
        h.plan_id,
        h.rendering_provider_npi,
        h.claim_type,
        h.claim_status,
        h.service_from_date,
        h.service_to_date,
        h.paid_date,

        -- line attributes / measures
        l.procedure_code,
        coalesce(l.charge_amount, 0)      as charge_amount,
        coalesce(l.allowed_amount, 0)     as allowed_amount,
        coalesce(l.paid_amount, 0)        as paid_amount,
        coalesce(l.units, 0)              as units,

        -- header-level patient responsibility + allocation basis
        coalesce(h.patient_responsibility, 0) as hdr_patient_responsibility,
        b.hdr_line_allowed_total,
        b.hdr_line_count,

        -- flags
        coalesce(d.is_denied, false)      as denial_flag,
        d.denial_reason_code,
        coalesce(ac.has_adjustment, false) as adjustment_flag,
        coalesce(ac.has_reversal, false)   as reversal_flag

    from lines l
    inner join current_header h
        on l.claim_id = h.claim_id
       and l.claim_version = h.claim_version
    left join header_alloc_basis b
        on l.claim_id = b.claim_id
       and l.claim_version = b.claim_version
    left join denial d
        on l.claim_id = d.claim_id
       and l.claim_version = d.claim_version
       and l.claim_line_id = d.claim_line_id
    left join adjustment_chain ac
        on l.claim_id = ac.claim_id

),

final as (

    select
        -- ---- surrogate key (unique per fact row) ---------------------------
        {{ generate_surrogate_key(['claim_id', 'claim_line_id', 'claim_version']) }}
                                                               as fact_claim_line_sk,

        -- ---- dimension FKs --------------------------------------------------
        {{ generate_surrogate_key(['member_id']) }}            as patient_sk,
        {{ generate_surrogate_key(['rendering_provider_npi']) }} as provider_sk,
        {{ generate_surrogate_key(['payer_id']) }}             as payer_sk,
        {{ generate_surrogate_key(['plan_id']) }}              as plan_sk,
        {{ generate_surrogate_key(['claim_id']) }}             as claim_header_sk,
        cast(to_char(service_from_date, 'YYYYMMDD') as integer) as date_sk,
        {{ generate_surrogate_key(['procedure_code']) }}       as procedure_sk,

        -- ---- retained natural keys (traceability) --------------------------
        claim_id,
        claim_line_id,
        claim_version,
        member_id,
        rendering_provider_npi,
        payer_id,
        plan_id,
        procedure_code,

        -- ---- header attributes carried for convenience ---------------------
        claim_type,
        claim_status,
        service_from_date,
        service_to_date,
        paid_date,

        -- ---- additive measures ---------------------------------------------
        charge_amount,
        allowed_amount,
        paid_amount,

        -- Line-allocated patient responsibility (additive; reconciles to header).
        case
            when hdr_line_allowed_total > 0
                then hdr_patient_responsibility * (allowed_amount / hdr_line_allowed_total)
            when hdr_line_count > 0
                then hdr_patient_responsibility / hdr_line_count
            else 0
        end                                                    as patient_responsibility,

        units,

        -- ---- derived analytic fields ---------------------------------------
        date_trunc('month', service_from_date)::date           as claim_month,
        year(service_from_date)                                as service_year,

        -- claim_setting: facility/professional/outpatient/inpatient rollup from
        -- claim_type. Kept small + tested via accepted_values.
        case
            when upper(claim_type) like '%INPATIENT%'    then 'Inpatient'
            when upper(claim_type) like '%OUTPATIENT%'   then 'Outpatient'
            when upper(claim_type) like '%PROFESSIONAL%' then 'Professional'
            when upper(claim_type) like '%FACILITY%'     then 'Facility'
            when upper(claim_type) like '%RX%'
              or upper(claim_type) like '%PHARMACY%'     then 'Pharmacy'
            else 'Other'
        end                                                    as claim_setting,

        denial_flag,
        denial_reason_code,
        adjustment_flag,
        reversal_flag,

        -- ---- audit ----------------------------------------------------------
        {{ audit_columns() }}

    from joined

)

select * from final
