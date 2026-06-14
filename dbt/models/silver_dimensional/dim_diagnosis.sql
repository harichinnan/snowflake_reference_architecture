-- =============================================================================
-- dim_diagnosis.sql
-- Layer: SILVER_DIMENSIONAL (conformed dimension)
-- Grain: one row per diagnosis code (diagnosis_sk).
--
-- Source: seed ref_diagnosis_code, left-joined to ref_condition_group via the
--         diagnosis code's condition-group mapping so each diagnosis carries
--         its clinical rollup. This is the dimension the diagnosis bridge and
--         the GOLD condition-cost product join to.
-- =============================================================================

{{
  config(
    materialized = 'table',
    tags = ['silver', 'dimensional', 'dimension', 'diagnosis']
  )
}}

-- CONFORMED dimension: must cover EVERY diagnosis code observed in claims, not
-- just the reference catalog -- otherwise the diagnosis bridge's FK to this dim
-- breaks for any real code outside the seed. We therefore build the code list
-- from observed claim diagnoses UNION the reference seed, then enrich from the
-- seed where a description exists. (Codes present in claims but absent from the
-- reference catalog are still flagged separately by the warn-severity
-- claim_diagnosis.diagnosis_code -> ref_diagnosis_code relationship test.)
with observed as (

    select distinct diagnosis_code
    from {{ ref('claim_diagnosis') }}
    where diagnosis_code is not null

),

seed as (

    select *
    from {{ ref('ref_diagnosis_code') }}

),

condition_group as (

    select *
    from {{ ref('ref_condition_group') }}

),

all_codes as (

    select diagnosis_code from observed
    union
    select diagnosis_code from seed

),

final as (

    select
        -- ---- surrogate key --------------------------------------------------
        {{ generate_surrogate_key(['ac.diagnosis_code']) }}    as diagnosis_sk,

        -- ---- natural key + attributes --------------------------------------
        ac.diagnosis_code,
        -- ref_diagnosis_code carries short_description; expose as `description`.
        -- Observed-but-unmapped codes get a clear placeholder.
        coalesce(s.short_description, 'Unmapped diagnosis (not in reference catalog)')
                                                               as description,
        coalesce(s.code_system, 'UNKNOWN')                     as code_system,  -- e.g. ICD-10-CM

        -- ---- clinical rollup -----------------------------------------------
        coalesce(cg.condition_group_code, 'UNGROUPED')         as condition_group_code,
        coalesce(cg.condition_group_name, 'Ungrouped')         as condition_group,

        -- FK to dim_condition_group (same hash derivation).
        {{ generate_surrogate_key(['coalesce(cg.condition_group_code, \'UNGROUPED\')']) }}
                                                               as condition_group_sk,

        -- ---- audit ----------------------------------------------------------
        {{ audit_columns() }}

    from all_codes ac
    left join seed s
        on ac.diagnosis_code = s.diagnosis_code
    -- ref_diagnosis_code.condition_group holds the condition-group CODE
    -- (e.g. 'DIABETES'), which maps to ref_condition_group.condition_group_code.
    left join condition_group cg
        on s.condition_group = cg.condition_group_code

)

select * from final
