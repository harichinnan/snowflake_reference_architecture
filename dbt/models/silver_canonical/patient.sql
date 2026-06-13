-- =============================================================================
-- patient.sql
-- Layer: SILVER_CANONICAL (canonical entity)
-- Grain: one row per member_id (the current demographic state).
--
-- Purpose
--   Master patient/member entity. Demographics are sourced from eligibility
--   events (the authoritative source for member attributes). Members that only
--   appear on claims (no eligibility row yet) are still surfaced so claim FKs
--   resolve, but with NULL demographics.
--
--   We dedupe to the most recently observed eligibility event per member and
--   derive an age_band from birth_year relative to the current run date.
--
-- Keys
--   member_id  -- source natural key (preserved).
--   patient_sk -- stable surrogate via generate_surrogate_key(['member_id']).
-- =============================================================================

{{
  config(
    materialized   = 'incremental',
    incremental_strategy = 'merge',
    unique_key     = 'patient_sk',
    on_schema_change = 'append_new_columns',
    tags           = ['silver', 'canonical', 'entity', 'patient']
  )
}}

with eligibility as (

    select
        {{ variant_value('payload', 'member_id', 'string') }}            as member_id,
        {{ variant_value('payload', 'demographics.birth_year', 'number') }} as birth_year,
        {{ variant_value('payload', 'demographics.gender', 'string') }}  as gender,
        {{ variant_value('payload', 'demographics.state', 'string') }}   as state,
        {{ variant_value('payload', 'demographics.zip3', 'string') }}    as zip3,
        source_system,
        source_extract_ts,
        ingest_ts,
        business_event_ts,
        payload_hash,
        batch_id,
        load_id,
        pipeline_run_id
    from {{ ref('br_raw_eligibility_event') }}
    where record_status = 'VALID'

),

-- Members referenced by claims but possibly absent from eligibility. We keep
-- only the member_id so claim FKs always resolve to a patient row.
claim_members as (

    select distinct member_id
    from {{ ref('int_current_valid_claims') }}
    where member_id is not null

),

-- Latest demographic snapshot per member from eligibility.
elig_current as (

    select *
    from eligibility
    qualify row_number() over (
        partition by member_id
        order by business_event_ts desc nulls last, source_extract_ts desc, ingest_ts desc
    ) = 1

),

-- Union: every member from either source, demographics from eligibility when
-- present.
all_members as (

    select member_id from elig_current
    union
    select member_id from claim_members

),

final as (

    select
        m.member_id,
        e.birth_year,
        e.gender,
        e.state,
        e.zip3,

        -- Derived age (approximate; birth_year only) and a coarse age band.
        case when e.birth_year is not null
             then year(current_date()) - e.birth_year end              as approx_age,
        case
            when e.birth_year is null then 'UNKNOWN'
            when (year(current_date()) - e.birth_year) < 18  then '0-17'
            when (year(current_date()) - e.birth_year) < 35  then '18-34'
            when (year(current_date()) - e.birth_year) < 50  then '35-49'
            when (year(current_date()) - e.birth_year) < 65  then '50-64'
            else '65+'
        end                                                            as age_band,

        -- ---- surrogate + audit ----------------------------------------------
        {{ generate_surrogate_key(['m.member_id']) }}                  as patient_sk,
        true                                                           as is_current,
        coalesce(e.business_event_ts, current_timestamp())             as effective_from,
        cast(null as timestamp_ntz)                                    as effective_to,

        coalesce(e.source_system, 'CLAIM')                             as source_system,
        e.batch_id,
        e.load_id,
        e.pipeline_run_id,
        e.payload_hash,
        current_timestamp()                                            as created_at,
        current_timestamp()                                            as updated_at

    from all_members m
    left join elig_current e
        on m.member_id = e.member_id

)

select * from final
