-- =============================================================================
-- int_x12_claim_segments.sql
-- Layer: SILVER_CANONICAL (intermediate / staging for X12 837P)
-- Grain: one row per X12 segment (LATERAL FLATTEN of payload:segments).
--
-- Purpose
--   Explode the moov-io/x12 flat labeled JSON (one bronze row per X12 file)
--   into one row per segment, preserving document order via the flatten index.
--   Downstream canonical models (header / line / diagnosis) read from here and
--   filter / window over (source_file_name + interchange_control_number,
--   claim_seq, segment_index).
--
-- Key columns
--   segment_index : flatten .index -> monotonic position of the segment within
--                   payload:segments == X12 document order. Used to associate
--                   LX -> SV1 -> DTP within a claim_seq.
--   segment_name  : seg:_segment  (ISA/GS/ST/NM1/CLM/HI/LX/SV1/DTP/...).
--   claim_seq     : 0 = file/billing-provider-level (shared); >0 = a claim.
--   seg           : the entire segment object (VARIANT) for element navigation.
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags         = ['silver', 'canonical', 'x12', '837p', 'intermediate']
  )
}}

with source_rows as (

    select
        bronze_event_id,
        source_file_name,
        ingest_ts,
        payload,
        batch_id,
        load_id,
        pipeline_run_id
    from {{ source('bronze_x12', 'br_raw_x12_claim_json') }}
    -- Only conformed / valid landed files flow into the canonical layer.
    where coalesce(record_status, 'VALID') = 'VALID'

),

exploded as (

    select
        s.bronze_event_id,
        s.source_file_name,
        s.payload:interchange_control_number::string  as interchange_control_number,
        s.ingest_ts,
        -- flatten index = array position = X12 document order.
        f.index                                        as segment_index,
        f.value:_segment::string                       as segment_name,
        f.value:claim_seq::int                         as claim_seq,
        f.value                                        as seg,
        s.batch_id,
        s.load_id,
        s.pipeline_run_id
    from source_rows s,
         lateral flatten(input => s.payload:segments) f

)

select * from exploded
