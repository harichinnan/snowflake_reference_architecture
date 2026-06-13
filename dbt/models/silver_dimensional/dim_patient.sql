-- =============================================================================
-- dim_patient.sql
-- Layer: SILVER_DIMENSIONAL (conformed dimension)
-- Grain: one row per member (patient_sk).  SCD-light: we keep the *current*
--        conformed attributes for each member plus light effective/current
--        flags so facts can join on a stable surrogate key.
--
-- Source: silver_canonical.patient (one row per member, already deduped /
--         conformed upstream).  Synthetic data -- no PHI / PII.
--
-- Why SCD-light:
--   The canonical `patient` model carries effective dating per member version.
--   For the dimensional star we collapse to the latest valid version per member
--   (is_current = TRUE) so the analytic grain stays one-row-per-member, while
--   still surfacing record_effective_from / record_effective_to for lineage and
--   point-in-time reasoning. A full SCD-2 dimension can be layered on later from
--   a snapshot without changing the surrogate-key contract below.
--
-- Surrogate key:
--   patient_sk = hash(member_id). Stable across rebuilds because it is derived
--   from the natural key only (not from mutable attributes).
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags = ['silver', 'dimensional', 'dimension', 'patient']
  )
}}

with patient as (

    select *
    from {{ ref('patient') }}

),

-- Collapse to the current/latest valid record per member. The canonical model
-- is expected to expose is_current; if multiple rows still arrive we keep the
-- most recently effective one defensively.
current_patient as (

    select *
    from patient
    qualify row_number() over (
        partition by member_id
        order by
            coalesce(is_current, false) desc,
            record_effective_from desc nulls last
    ) = 1

),

final as (

    select
        -- ---- surrogate key --------------------------------------------------
        {{ generate_surrogate_key(['member_id']) }}            as patient_sk,

        -- ---- natural key ----------------------------------------------------
        member_id,

        -- ---- demographic attributes ----------------------------------------
        gender,
        birth_date,

        -- Age (in whole years) as of the current run date, then bucketed into
        -- standard actuarial age bands used for PMPM / cohort segmentation.
        datediff('year', birth_date, current_date())          as member_age,

        case
            when birth_date is null then 'Unknown'
            when datediff('year', birth_date, current_date()) < 18  then '0-17'
            when datediff('year', birth_date, current_date()) < 35  then '18-34'
            when datediff('year', birth_date, current_date()) < 50  then '35-49'
            when datediff('year', birth_date, current_date()) < 65  then '50-64'
            else '65+'
        end                                                   as age_band,

        -- ---- synthetic geography (no real addresses) -----------------------
        state,
        -- 3-digit ZIP prefix only (de-identified geography unit).
        left(coalesce(zip_code, ''), 3)                       as zip3,

        -- ---- SCD-light lineage / current flags -----------------------------
        coalesce(is_current, true)                            as is_current,
        record_effective_from,
        record_effective_to,

        -- ---- audit ----------------------------------------------------------
        {{ audit_columns() }}

    from current_patient

)

select * from final
