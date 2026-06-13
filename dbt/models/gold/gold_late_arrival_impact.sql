-- =============================================================================
-- gold_late_arrival_impact.sql
-- Layer: GOLD (CERTIFIED semantic data product)
--
-- Business question: "WHY did March paid change after the first load?" Quantify
-- how late-arriving claims restated a prior period's paid total.
--
-- GRAIN: one row per impacted service month (claim_month / impacted_period).
--
-- How it works
--   int_late_arriving_claims flags claim versions whose received/ingest date
--   fell well after the service month they belong to (i.e. they landed AFTER
--   that month was first reported). We split paid into:
--     original_paid  = paid from claims that arrived on time (not late)
--     late_paid      = paid contributed by late-arriving claims
--     restated_paid  = original_paid + late_paid (current truth in fact_claim_line)
--   The delta and pct change explain the post-load movement.
--
-- Certified context: this is the late-arrival explainability product surfaced to
-- MCP/Cortex for "why did the number move" questions.
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags = ['gold', 'mart', 'semantic', 'certified', 'late_arrival']
  )
}}

with fct as (

    select *
    from {{ ref('fact_claim_line') }}

),

-- Late-arriving claim keys + the period they impacted.
late as (

    select distinct
        claim_id,
        claim_version,
        impacted_period            -- service month the late claim restated
    from {{ ref('int_late_arriving_claims') }}

),

-- Tag each fact line as late or on-time.
tagged as (

    select
        f.claim_month,
        f.paid_amount,
        case when l.claim_id is not null then true else false end as is_late_arriving
    from fct f
    left join late l
        on f.claim_id = l.claim_id
       and f.claim_version = l.claim_version

),

final as (

    select
        claim_month                            as impacted_period,

        -- original_paid: what the month would have shown WITHOUT late arrivals.
        sum(case when not is_late_arriving then paid_amount else 0 end)
                                               as original_paid,

        -- late_paid: paid added by claims that landed after the month closed.
        sum(case when is_late_arriving then paid_amount else 0 end)
                                               as late_paid,

        -- restated_paid: current certified total (matches fact_claim_line).
        sum(paid_amount)                       as restated_paid,

        -- movement
        sum(case when is_late_arriving then paid_amount else 0 end)
                                               as paid_delta,
        case
            when sum(case when not is_late_arriving then paid_amount else 0 end) > 0
            then sum(case when is_late_arriving then paid_amount else 0 end)
                 / sum(case when not is_late_arriving then paid_amount else 0 end)
            else null
        end                                    as paid_pct_change,

        sum(case when is_late_arriving then 1 else 0 end) as late_arriving_line_count

    from tagged
    group by 1

)

select * from final
