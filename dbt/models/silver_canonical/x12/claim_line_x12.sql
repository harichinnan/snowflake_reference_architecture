-- =============================================================================
-- claim_line_x12.sql
-- Layer: SILVER_CANONICAL (canonical entity)
-- Grain: one row per X12 837P service line (one SV1 segment, claim_seq > 0).
--
-- Purpose
--   Parse service-line detail from SV1 segments and associate each SV1 with:
--     * its line number  -> the LX with the greatest segment_index < the SV1's
--                           index, within the same claim_seq (last LX before SV1)
--     * its service date -> the DTP (01 = '472') with the smallest segment_index
--                           > the SV1's index, within the same claim_seq
--                           (first 472-DTP after SV1)
--   Association is purely positional (document order via segment_index),
--   partitioned by (source_file_name, interchange_control_number, claim_seq).
--
--   SV1:01 is a string "HC<87086": qualifier = split_part(...,'<',1),
--   procedure code = split_part(...,'<',2).
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags         = ['silver', 'canonical', 'x12', '837p', 'entity', 'claim', 'line']
  )
}}

with segments as (

    select *
    from {{ ref('int_x12_claim_segments') }}
    where claim_seq > 0

),

sv1 as (
    select
        source_file_name,
        interchange_control_number,
        claim_seq,
        segment_index,
        bronze_event_id,
        batch_id,
        load_id,
        pipeline_run_id,
        split_part(seg:"01"::string, '<', 1)        as procedure_qualifier,
        split_part(seg:"01"::string, '<', 2)        as procedure_code,
        try_cast(seg:"02"::string as number(18,2))  as line_charge_amount,
        try_cast(seg:"04"::string as number(18,4))  as units
    from segments
    where segment_name = 'SV1'
),

lx as (
    select
        source_file_name,
        interchange_control_number,
        claim_seq,
        segment_index,
        seg:"01"::string as line_number
    from segments
    where segment_name = 'LX'
),

-- '472' = service date qualifier.
dtp as (
    select
        source_file_name,
        interchange_control_number,
        claim_seq,
        segment_index,
        try_to_date(seg:"03"::string, 'YYYYMMDD') as service_date
    from segments
    where segment_name = 'DTP'
      and seg:"01"::string = '472'
),

-- Last LX strictly before each SV1 in the same claim_seq.
sv1_to_lx as (
    select
        s.source_file_name,
        s.interchange_control_number,
        s.claim_seq,
        s.segment_index                              as sv1_index,
        max(l.segment_index)                         as lx_index
    from sv1 s
    left join lx l
        on  s.source_file_name           = l.source_file_name
        and s.interchange_control_number = l.interchange_control_number
        and s.claim_seq                  = l.claim_seq
        and l.segment_index              < s.segment_index
    group by 1, 2, 3, 4
),

-- First 472-DTP strictly after each SV1 in the same claim_seq.
sv1_to_dtp as (
    select
        s.source_file_name,
        s.interchange_control_number,
        s.claim_seq,
        s.segment_index                              as sv1_index,
        min(d.segment_index)                         as dtp_index
    from sv1 s
    left join dtp d
        on  s.source_file_name           = d.source_file_name
        and s.interchange_control_number = d.interchange_control_number
        and s.claim_seq                  = d.claim_seq
        and d.segment_index              > s.segment_index
    group by 1, 2, 3, 4
),

-- CLM:01 = claim_id, per claim_seq, for keying back to the header.
clm as (
    select
        source_file_name,
        interchange_control_number,
        claim_seq,
        seg:"01"::string as claim_id
    from segments
    where segment_name = 'CLM'
    qualify row_number() over (
        partition by source_file_name, interchange_control_number, claim_seq
        order by segment_index
    ) = 1
),

final as (
    select
        -- ---- surrogate -------------------------------------------------------
        {{ generate_surrogate_key([
            's.source_file_name',
            's.interchange_control_number',
            's.claim_seq',
            'l.line_number'
        ]) }}                                              as claim_line_sk,

        -- ---- header link -----------------------------------------------------
        {{ generate_surrogate_key([
            's.interchange_control_number',
            's.claim_seq',
            'c.claim_id'
        ]) }}                                              as claim_header_sk,

        -- ---- natural keys ----------------------------------------------------
        s.source_file_name,
        s.interchange_control_number,
        s.claim_seq,
        c.claim_id,
        l.line_number,

        -- ---- service line ----------------------------------------------------
        s.procedure_qualifier,
        s.procedure_code,
        s.line_charge_amount,
        s.units,
        dt.service_date,

        -- ---- audit -----------------------------------------------------------
        {{ audit_columns(
            source_system="'SYNTH_X12_837P'",
            batch_id='s.batch_id',
            load_id='s.load_id',
            pipeline_run_id='s.pipeline_run_id'
        ) }}
    from sv1 s
    left join sv1_to_lx ml
        on  s.source_file_name           = ml.source_file_name
        and s.interchange_control_number = ml.interchange_control_number
        and s.claim_seq                  = ml.claim_seq
        and s.segment_index              = ml.sv1_index
    left join lx l
        on  ml.source_file_name           = l.source_file_name
        and ml.interchange_control_number = l.interchange_control_number
        and ml.claim_seq                  = l.claim_seq
        and ml.lx_index                   = l.segment_index
    left join sv1_to_dtp md
        on  s.source_file_name           = md.source_file_name
        and s.interchange_control_number = md.interchange_control_number
        and s.claim_seq                  = md.claim_seq
        and s.segment_index              = md.sv1_index
    left join dtp dt
        on  md.source_file_name           = dt.source_file_name
        and md.interchange_control_number = dt.interchange_control_number
        and md.claim_seq                  = dt.claim_seq
        and md.dtp_index                  = dt.segment_index
    left join clm c
        on  s.source_file_name           = c.source_file_name
        and s.interchange_control_number = c.interchange_control_number
        and s.claim_seq                  = c.claim_seq
)

select * from final
