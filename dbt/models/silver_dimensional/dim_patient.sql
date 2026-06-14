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
            effective_from desc nulls last   -- canonical patient uses effective_from
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
        -- Canonical patient is de-identified to birth_year (no full birth_date).
        birth_year,

        -- Age + age band are derived upstream in canonical.patient from
        -- birth_year; carry them through (approx_age == whole-year age).
        approx_age                                            as member_age,
        age_band,

        -- ---- synthetic geography (no real addresses) -----------------------
        state,
        -- zip3 (3-digit de-identified ZIP prefix) is already conformed upstream.
        zip3,

        -- ---- SCD-light lineage / current flags -----------------------------
        -- NOTE: is_current is emitted by audit_columns() below; do not also
        -- select it here or Snowflake errors with duplicate column 'IS_CURRENT'.
        -- Canonical patient exposes effective_from / effective_to (not
        -- record_effective_*); surface them under the dim's lineage names.
        effective_from                                        as record_effective_from,
        effective_to                                          as record_effective_to,

        -- ---- audit (provides is_current, effective_from/to, source_system,
        --      batch_id, load_id, pipeline_run_id, payload_hash, timestamps) ---
        {{ audit_columns() }}

    from current_patient

)

select * from final
