-- =============================================================================
-- control_reprocessing_ledger.sql
-- CONTROL :: queryable projection of the reprocessing ledger.
--
-- DCM Domain G (Reprocessing). Surfaces CONTROL.REPROCESSING_LEDGER so the
-- audit trail of every backfill / replay is visible: which original batch was
-- replaced by which reprocess batch, why, the scope, who requested/approved it,
-- the lifecycle status, row counts before/after, and the post-run validation
-- outcome.
-- =============================================================================

{{ config(materialized='table', tags=['control', 'dcm_g_reprocessing']) }}

with ledger as (

    select *
    from {{ source('control', 'reprocessing_ledger') }}

)

select
    reprocessing_id,
    pipeline_name,

    -- Batch lineage (DCM B/G): original vs. replacement batch.
    original_batch_id,
    reprocess_batch_id,

    -- Justification + blast radius.
    reason,
    scope,                  -- e.g. period / natural-key set being reprocessed

    -- Governance / approvals (DCM G).
    requested_by,
    requested_at,
    approved_by,
    approved_at,

    -- Lifecycle.
    status,                 -- REQUESTED / APPROVED / RUNNING / COMPLETED / FAILED / REJECTED

    -- Reconciliation: row counts before and after the reprocess.
    rows_before,
    rows_after,
    (coalesce(rows_after, 0) - coalesce(rows_before, 0)) as rows_delta,

    -- Post-run data-quality gate (DCM E/G).
    validation_status,      -- PASS / FAIL / PENDING
    completed_at
from ledger
