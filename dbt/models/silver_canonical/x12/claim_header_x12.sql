-- =============================================================================
-- claim_header_x12.sql
-- Layer: SILVER_CANONICAL (canonical entity)
-- Grain: one row per (interchange_control_number, claim_seq) where claim_seq > 0
--        == one row per distinct claim in the X12 837P file.
--
-- Purpose
--   The conformed claim header parsed from X12 837P segments. Each role is
--   pulled from a filtered CTE over int_x12_claim_segments and joined back to
--   the CLM (claim) anchor:
--     CLM       (claim_seq > 0)        -> claim_id, total_charge, place_of_service
--     NM1 IL    (same claim_seq)       -> subscriber last/first/member_id
--     NM1 PR    (same claim_seq)       -> payer name / id
--     NM1 82    (same claim_seq)       -> rendering provider npi
--     NM1 85    (claim_seq = 0, file)  -> billing provider npi / name (shared)
--     DTP       (same claim_seq)       -> service_date = min DTP:03 for the claim
--
--   The file grain is (source_file_name, interchange_control_number); the
--   billing-provider NM1 lives at claim_seq = 0 and is shared across all claims
--   in the same file, so it joins on the file key only.
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags         = ['silver', 'canonical', 'x12', '837p', 'entity', 'claim', 'header']
  )
}}

with segments as (

    select *
    from {{ ref('int_x12_claim_segments') }}

),

-- ---- CLM: claim anchor (one per claim_seq > 0) -----------------------------
clm as (
    select
        source_file_name,
        interchange_control_number,
        claim_seq,
        bronze_event_id,
        ingest_ts,
        batch_id,
        load_id,
        pipeline_run_id,
        seg:"01"::string                                          as claim_id,
        try_cast(seg:"02"::string as number(18,2))                as total_charge_amount,
        -- CLM:05 is usually a nested object {"01":POS,...}; fall back to a
        -- scalar string when it is not nested.
        coalesce(
            seg:"05":"01"::string,
            try_cast(seg:"05"::string as string)
        )                                                          as place_of_service
    from segments
    where segment_name = 'CLM'
      and claim_seq > 0
),

-- ---- NM1 IL: subscriber / patient (same claim_seq) -------------------------
subscriber as (
    select
        source_file_name,
        interchange_control_number,
        claim_seq,
        seg:"03"::string as subscriber_last_name,
        seg:"04"::string as subscriber_first_name,
        seg:"09"::string as subscriber_member_id
    from segments
    where segment_name = 'NM1'
      and seg:"01"::string = 'IL'
      and claim_seq > 0
    -- Defensive: at most one IL per claim_seq; keep the earliest segment.
    qualify row_number() over (
        partition by source_file_name, interchange_control_number, claim_seq
        order by segment_index
    ) = 1
),

-- ---- NM1 PR: payer (same claim_seq) ----------------------------------------
payer as (
    select
        source_file_name,
        interchange_control_number,
        claim_seq,
        seg:"03"::string as payer_name,
        seg:"09"::string as payer_id
    from segments
    where segment_name = 'NM1'
      and seg:"01"::string = 'PR'
      and claim_seq > 0
    qualify row_number() over (
        partition by source_file_name, interchange_control_number, claim_seq
        order by segment_index
    ) = 1
),

-- ---- NM1 82: rendering provider (same claim_seq) ---------------------------
rendering as (
    select
        source_file_name,
        interchange_control_number,
        claim_seq,
        seg:"09"::string as rendering_provider_npi
    from segments
    where segment_name = 'NM1'
      and seg:"01"::string = '82'
      and claim_seq > 0
    qualify row_number() over (
        partition by source_file_name, interchange_control_number, claim_seq
        order by segment_index
    ) = 1
),

-- ---- NM1 85: billing provider (file-level, claim_seq = 0, shared) ----------
billing as (
    select
        source_file_name,
        interchange_control_number,
        seg:"09"::string as billing_provider_npi,
        seg:"03"::string as billing_provider_name
    from segments
    where segment_name = 'NM1'
      and seg:"01"::string = '85'
      and claim_seq = 0
    qualify row_number() over (
        partition by source_file_name, interchange_control_number
        order by segment_index
    ) = 1
),

-- ---- DTP: service date = min DTP:03 for the claim --------------------------
service_dt as (
    select
        source_file_name,
        interchange_control_number,
        claim_seq,
        min(try_to_date(seg:"03"::string, 'YYYYMMDD')) as service_date
    from segments
    where segment_name = 'DTP'
      and claim_seq > 0
    group by 1, 2, 3
),

final as (
    select
        -- ---- surrogate -------------------------------------------------------
        {{ generate_surrogate_key([
            'clm.interchange_control_number',
            'clm.claim_seq',
            'clm.claim_id'
        ]) }}                                              as claim_header_sk,

        -- ---- natural keys ----------------------------------------------------
        clm.source_file_name,
        clm.interchange_control_number,
        clm.claim_seq,
        clm.claim_id,

        -- ---- claim financials / classification -------------------------------
        clm.total_charge_amount,
        clm.place_of_service,

        -- ---- subscriber ------------------------------------------------------
        sub.subscriber_last_name,
        sub.subscriber_first_name,
        sub.subscriber_member_id,

        -- ---- payer -----------------------------------------------------------
        pyr.payer_name,
        pyr.payer_id,

        -- ---- providers -------------------------------------------------------
        bill.billing_provider_npi,
        bill.billing_provider_name,
        rnd.rendering_provider_npi,

        -- ---- dates -----------------------------------------------------------
        sdt.service_date,

        -- ---- audit -----------------------------------------------------------
        {{ audit_columns(
            source_system="'SYNTH_X12_837P'",
            batch_id='clm.batch_id',
            load_id='clm.load_id',
            pipeline_run_id='clm.pipeline_run_id'
        ) }}
    from clm
    left join subscriber sub
        on  clm.source_file_name           = sub.source_file_name
        and clm.interchange_control_number = sub.interchange_control_number
        and clm.claim_seq                  = sub.claim_seq
    left join payer pyr
        on  clm.source_file_name           = pyr.source_file_name
        and clm.interchange_control_number = pyr.interchange_control_number
        and clm.claim_seq                  = pyr.claim_seq
    left join rendering rnd
        on  clm.source_file_name           = rnd.source_file_name
        and clm.interchange_control_number = rnd.interchange_control_number
        and clm.claim_seq                  = rnd.claim_seq
    left join billing bill
        on  clm.source_file_name           = bill.source_file_name
        and clm.interchange_control_number = bill.interchange_control_number
    left join service_dt sdt
        on  clm.source_file_name           = sdt.source_file_name
        and clm.interchange_control_number = sdt.interchange_control_number
        and clm.claim_seq                  = sdt.claim_seq
)

select * from final
