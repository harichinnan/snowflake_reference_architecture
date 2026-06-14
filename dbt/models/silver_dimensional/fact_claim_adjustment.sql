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
        -- adjudication_event has no plain claim_version; new_claim_version is the
        -- version this event produced. (prior_claim_version is the predecessor.)
        e.new_claim_version                   as claim_version,
        -- No event_seq on adjudication_event; the event's own id is its sequence
        -- identity and is used to make the fact's surrogate key unique.
        e.adjudication_event_id               as event_seq,
        e.event_ts,
        e.event_type,                       -- ADJUSTMENT | VOID | REVERSAL | PAY
        -- adjudication_event already carries the signed paid_amount delta for the
        -- version transition; no prior/new paid columns to difference.
        coalesce(e.paid_amount_delta, 0)      as paid_amount_delta,
        -- Lifecycle flags come from the reconstructed chain (is_reversal/is_void);
        -- adjudication_event has no reversal/void indicator columns.
        coalesce(c.is_reversal, false)        as reversal_flag,
        coalesce(c.is_void, false)            as void_flag,

        c.original_claim_id

    from events e
    left join chain c
        on e.claim_id = c.claim_id
       and e.new_claim_version = c.claim_version

),

final as (

    select
        -- ---- surrogate key --------------------------------------------------
        {{ generate_surrogate_key(['claim_id', 'claim_version', 'event_seq']) }}
                                                               as fact_claim_adjustment_sk,

        -- ---- dimension FKs --------------------------------------------------
        cast(to_char(event_ts, 'YYYYMMDD') as integer)         as date_sk,
        -- adjudication_event carries no payer_id (and the adjustment chain has no
        -- payer either), so the payer FK is NULL on this event fact.
        cast(null as string)                                   as payer_sk,

        -- ---- retained natural keys -----------------------------------------
        claim_id,
        claim_version,
        original_claim_id,
        event_seq,

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
        -- version, taken directly from adjudication_event.paid_amount_delta.
        -- Summing paid_amount_delta over a claim's chain ties back to the
        -- claim's current paid total.
        paid_amount_delta,
        1                                                      as event_count,
        case when reversal_flag then 1 else 0 end              as reversal_count,
        case when void_flag     then 1 else 0 end              as void_count,

        -- ---- audit ----------------------------------------------------------
        {{ audit_columns() }}

    from joined

)

select * from final
