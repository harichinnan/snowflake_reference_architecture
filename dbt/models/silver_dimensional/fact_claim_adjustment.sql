-- =============================================================================
-- fact_claim_adjustment.sql
-- Layer: SILVER_DIMENSIONAL (event / accumulating-history fact)
--
-- GRAIN: one row per claim lifecycle event -- an adjudication adjustment, void,
--        or reversal. This is the audit-trail fact that explains HOW a claim's
--        paid amount moved over time. fact_claim_line holds only the *current*
--        truth; this fact holds the deltas that produced it.
--
-- Source
--   adjudication_event (the raw event stream of adjustment/void/reversal/pay
--   events) joined to int_claim_adjustment_chain (which links each version to
--   its root claim and prior version) so each event knows its place in the
--   chain and its paid-amount delta vs the prior version.
--
-- Keys
--   fact_claim_adjustment_sk = hash(claim_id, claim_version, event_seq)
--   FKs: date_sk (event_ts), payer_sk.
--   Natural keys RETAINED: claim_id, claim_version, original_claim_id.
--
-- Measures: paid_amount_delta (signed: new paid - prior paid), event_count(=1),
--   reversal_count, void_count.
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags = ['silver', 'dimensional', 'fact', 'adjustment']
  )
}}

with events as (

    select *
    from {{ ref('adjudication_event') }}

),

chain as (

    select *
    from {{ ref('int_claim_adjustment_chain') }}

),

joined as (

    select
        e.claim_id,
        e.claim_version,
        e.event_seq,
        e.event_ts,
        e.event_type,                       -- ADJUSTMENT | VOID | REVERSAL | PAY
        e.payer_id,
        e.paid_amount,
        coalesce(e.reversal_indicator, false) as reversal_flag,
        coalesce(e.void_indicator, false)     as void_flag,

        c.original_claim_id,
        c.prior_paid_amount

    from events e
    left join chain c
        on e.claim_id = c.claim_id
       and e.claim_version = c.claim_version

),

final as (

    select
        -- ---- surrogate key --------------------------------------------------
        {{ generate_surrogate_key(['claim_id', 'claim_version', 'event_seq']) }}
                                                               as fact_claim_adjustment_sk,

        -- ---- dimension FKs --------------------------------------------------
        cast(to_char(event_ts, 'YYYYMMDD') as integer)         as date_sk,
        {{ generate_surrogate_key(['payer_id']) }}             as payer_sk,

        -- ---- retained natural keys -----------------------------------------
        claim_id,
        claim_version,
        original_claim_id,
        event_seq,
        payer_id,

        -- ---- attributes -----------------------------------------------------
        event_ts,

        -- adjustment_type: normalized event classification (tested via
        -- accepted_values).
        case
            when reversal_flag then 'REVERSAL'
            when void_flag     then 'VOID'
            when upper(coalesce(event_type, '')) like '%ADJUST%' then 'ADJUSTMENT'
            else 'OTHER'
        end                                                    as adjustment_type,

        reversal_flag,
        void_flag,

        -- ---- measures -------------------------------------------------------
        -- Signed change in paid amount this event contributed vs the prior
        -- version. Summing paid_amount_delta over a claim's chain ties back to
        -- the claim's current paid total.
        coalesce(paid_amount, 0) - coalesce(prior_paid_amount, 0)
                                                               as paid_amount_delta,
        1                                                      as event_count,
        case when reversal_flag then 1 else 0 end              as reversal_count,
        case when void_flag     then 1 else 0 end              as void_count,

        -- ---- audit ----------------------------------------------------------
        {{ audit_columns() }}

    from joined

)

select * from final
