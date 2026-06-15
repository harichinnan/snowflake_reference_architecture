-- =============================================================================
-- claim_diagnosis_x12.sql
-- Layer: SILVER_CANONICAL (canonical entity)
-- Grain: one row per diagnosis on a claim (one HI element, claim_seq > 0).
--
-- Purpose
--   Unpivot the HI (Health Care Diagnosis) segments. Each HI segment carries up
--   to twelve diagnosis elements at keys "01".."12", each a nested object
--   {"01": qualifier, "02": diagnosis_code}:
--     qualifier  BK = principal diagnosis, BF = other diagnosis.
--   We FLATTEN the HI segment object and keep only the element entries whose
--   key is a 2-digit element label and whose value carries a diagnosis code,
--   then number them 1..n by element-key order as diagnosis_position.
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags         = ['silver', 'canonical', 'x12', '837p', 'entity', 'claim', 'diagnosis']
  )
}}

with segments as (

    select *
    from {{ ref('int_x12_claim_segments') }}
    where claim_seq > 0
      and segment_name = 'HI'

),

clm as (
    select
        source_file_name,
        interchange_control_number,
        claim_seq,
        seg:"01"::string as claim_id
    from {{ ref('int_x12_claim_segments') }}
    where claim_seq > 0
      and segment_name = 'CLM'
    qualify row_number() over (
        partition by source_file_name, interchange_control_number, claim_seq
        order by segment_index
    ) = 1
),

-- Explode the HI segment object into its element entries (key -> nested obj).
elements as (
    select
        h.source_file_name,
        h.interchange_control_number,
        h.claim_seq,
        h.bronze_event_id,
        h.batch_id,
        h.load_id,
        h.pipeline_run_id,
        f.key                       as element_key,
        f.value:"01"::string        as qualifier,
        f.value:"02"::string        as diagnosis_code
    from segments h,
         lateral flatten(input => h.seg) f
    -- Keep only the positional diagnosis elements (skip _segment / claim_seq and
    -- any element that does not carry a diagnosis code).
    where f.key rlike '^[0-9]{2}$'
      and f.value:"02"::string is not null
),

final as (
    select
        -- ---- header link -----------------------------------------------------
        {{ generate_surrogate_key([
            'e.interchange_control_number',
            'e.claim_seq',
            'c.claim_id'
        ]) }}                                              as claim_header_sk,

        -- ---- natural keys ----------------------------------------------------
        e.source_file_name,
        e.interchange_control_number,
        e.claim_seq,
        c.claim_id,

        -- ---- diagnosis -------------------------------------------------------
        e.diagnosis_code,
        e.qualifier,
        -- Position 1..n by element-key order (01,02,...,12) within the claim.
        row_number() over (
            partition by e.source_file_name, e.interchange_control_number, e.claim_seq
            order by e.element_key
        )                                                  as diagnosis_position,
        (e.qualifier = 'BK')                               as is_principal,

        -- ---- audit -----------------------------------------------------------
        {{ audit_columns(
            source_system="'SYNTH_X12_837P'",
            batch_id='e.batch_id',
            load_id='e.load_id',
            pipeline_run_id='e.pipeline_run_id'
        ) }}
    from elements e
    left join clm c
        on  e.source_file_name           = c.source_file_name
        and e.interchange_control_number = c.interchange_control_number
        and e.claim_seq                  = c.claim_seq
)

select * from final
