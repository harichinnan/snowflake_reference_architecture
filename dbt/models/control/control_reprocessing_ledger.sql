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
    -- REPROCESSING_LEDGER PK is reprocess_batch_id (no separate reprocessing_id).
    reprocess_batch_id,
    pipeline_name,

    -- Batch lineage (DCM B/G): original vs. replacement batch.
    original_batch_id,

    -- Justification + blast radius (ledger columns are reprocess_reason / _scope).
    reprocess_reason  as reason,
    reprocess_scope   as scope,   -- e.g. period / natural-key set being reprocessed

    -- Governance / approvals (DCM G). The ledger tracks requester/approver plus
    -- the run lifecycle timestamps started_at / completed_at (no separate
    -- requested_at / approved_at columns exist).
    requested_by,
    approved_by,
    started_at,

    -- Lifecycle.
    status,                 -- REQUESTED / APPROVED / RUNNING / COMPLETED / FAILED / REJECTED

    -- Reconciliation: rows reprocessed by the replay (no before/after split in
    -- the ledger; only the reprocessed row count is recorded).
    rows_reprocessed,

    -- Post-run data-quality gate (DCM E/G).
    validation_status,      -- PASS / FAIL / PENDING
    completed_at
from ledger
