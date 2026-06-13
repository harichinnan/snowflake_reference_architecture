/* =============================================================================
   claims_runbook_seed.sql
   snowflake-claims-platform :: Operational runbook seed
   -----------------------------------------------------------------------------
   Populates SEMANTIC.CLAIMS_RUNBOOK with Q&A / runbook docs that Cortex Search
   (CLAIMS_DATA_QUALITY_SEARCH) retrieves to explain operational behaviour:
     - how late-arriving claims work and why prior-month paid can change
     - the adjustment / reversal model
     - what each quality failure means
     - how PMPM is computed
     - what is quarantined and why

   SYNTHETIC DATA. Not real CMS/Medicaid/PHI.

   SCHEMA (assumed; aligns with the Cortex Search source query in
   cortex_search_objects.sql):
     CLAIMS_RUNBOOK(doc_id, topic, question, answer, tags, created_at)

   NOTE: snowflake/setup/012 may create CLAIMS_RUNBOOK with the alternate shape
   (runbook_id, title, category, content). If so, ALTER it to this Q&A shape (or
   add these columns) so the search service and this seed agree — both use
   doc_id/topic/question/answer/tags. The defensive CREATE below makes that shape.

   IDEMPOTENT: MERGE upserts by doc_id. Run as CLAIMS_SYSADMIN.
   ============================================================================= */

USE ROLE CLAIMS_SYSADMIN;
USE DATABASE CLAIMS_PROD;          -- swap to CLAIMS_DEV for the dev deploy
USE SCHEMA SEMANTIC;

-- Defensive create in the Q&A shape consumed by Cortex Search.
CREATE TABLE IF NOT EXISTS SEMANTIC.CLAIMS_RUNBOOK (
    doc_id      STRING,
    topic       STRING,
    question    STRING,
    answer      STRING,
    tags        STRING,
    created_at  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

MERGE INTO SEMANTIC.CLAIMS_RUNBOOK tgt
USING (
    SELECT column1 AS doc_id,
           column2 AS topic,
           column3 AS question,
           column4 AS answer,
           column5 AS tags
    FROM VALUES
    (
      'RB_LATE_ARRIVAL_01',
      'Late-arriving claims',
      'How do late-arriving (runout) claims work, and why can a prior month''s paid change after the first load?',
      'Claims are attributed to the SERVICE month (claim_month / impacted_period), not the month they were received. A claim for a March service can be submitted and adjudicated weeks or months later (claim "runout"). When it lands, it is attributed back to March, so March''s paid total INCREASES after March first closed. The platform handles this with a lookback window (lookback_days) and a late-arrival window (late_arrival_days, default 30) in CONTROL.PIPELINE_CONFIG, re-scanning recent periods each run so late claims are captured. GOLD.gold_late_arrival_impact quantifies the movement per month: original_paid (what the month first showed) + late_paid (added by late arrivals) = restated_paid (current truth, matching fact_claim_line). This is EXPECTED behaviour, not a data error.',
      'late_arrival,runout,restatement,paid,freshness,lookback'
    ),
    (
      'RB_PRIOR_MONTH_CHANGE_01',
      'Prior-month restatement',
      'Why did last month''s paid number change since I last looked?',
      'Two mechanisms restate a prior month: (1) LATE-ARRIVING claims attributed back to that service month (see gold_late_arrival_impact); and (2) ADJUSTMENTS / REVERSALS that replace or back out a prior claim version. fact_claim_line always reflects the CURRENT valid version, so when an adjustment lands, the month''s paid moves to the corrected amount. To explain a specific movement, query gold_late_arrival_impact for the month and check adjustment_flag / reversal_flag counts in gold_claims_semantic_base for that claim_month.',
      'restatement,prior_month,adjustment,reversal,late_arrival,paid'
    ),
    (
      'RB_ADJUSTMENT_REVERSAL_01',
      'Adjustment / reversal model',
      'How does the adjustment / reversal model work, and does it double-count dollars?',
      'Each claim can be corrected over time through an ADJUSTMENT chain. An ADJUSTMENT issues a new claim_version that replaces the prior one with corrected amounts; a REVERSAL / VOID backs out a prior version. fact_claim_line contains ONLY the current valid version of each claim (selected by int_current_valid_claims), so summing paid_amount never double-counts across the chain. The full history of deltas lives in fact_claim_adjustment, where paid_amount_delta (new paid - prior paid) sums over a claim''s chain back to its current paid. adjustment_flag / reversal_flag on the semantic base let you see that a claim was adjusted/reversed without changing the certified dollar totals. Certified metrics: adjustment_count = COUNT(DISTINCT CASE WHEN adjustment_flag THEN claim_id END); reversal_count likewise.',
      'adjustment,reversal,void,chain,double_count,claim_version,delta'
    ),
    (
      'RB_PMPM_01',
      'PMPM computation',
      'How is PMPM computed, and what is the denominator?',
      'PMPM (per member per month) = total paid / member months. The NUMERATOR is certified paid (SUM(paid_amount), surfaced as gold_payer_plan_summary.total_paid). The DENOMINATOR is member_months from gold_member_months — the single certified denominator, derived from fact_eligibility_month where each covered (member, payer, plan, month) contributes one member month. The two are joined on payer_sk / plan_sk / month so PMPM means exactly one thing platform-wide. PMPM is NULL when member_months = 0. When aggregating across rows, recompute SUM(total_paid) / SUM(member_months) — never average a pre-computed pmpm column.',
      'pmpm,member_months,denominator,paid,eligibility,certified'
    ),
    (
      'RB_PAID_ALLOWED_CHARGE_01',
      'Amount definitions',
      'What is the difference between paid, allowed, charge, and patient responsibility?',
      'CHARGE (charge_amount) is the billed / submitted gross amount. ALLOWED (allowed_amount) is the contractually allowed amount, where allowed = paid + patient_responsibility. PAID (paid_amount) is what the payer actually paid. PATIENT_RESPONSIBILITY is the member cost share (copay + coinsurance + deductible), line-allocated from the header in proportion to line allowed. Generally charge >= allowed >= paid. When a user says "cost" or "spend", default to PAID and state that you did; offer allowed or charge if they may have meant those.',
      'paid,allowed,charge,patient_responsibility,definitions,cost'
    ),
    (
      'RB_DENIAL_RATE_01',
      'Denial rate',
      'How is denial rate computed and how should I aggregate it?',
      'denial_rate = denied_claims / total_claims, computed per slice in gold_claim_denial_summary (grain: payer x plan x status x reason x month). Rows with denial_reason = "Not Denied" are the clean-claim slice. To aggregate across slices, SUM the numerator and denominator separately and divide — SUM(denied_claims) / NULLIF(SUM(total_claims), 0) — do NOT average the pre-computed denial_rate column, which would weight slices incorrectly.',
      'denial,denial_rate,aggregation,ratio,certified'
    ),
    (
      'RB_QUARANTINE_01',
      'Quarantine',
      'What gets quarantined, and why?',
      'Records that fail a hard data contract or critical quality rule at ingest are routed OUT of the happy path into AUDIT.QUARANTINE_RECORD rather than landing in the modeled tables. Typical reasons: missing required business keys (e.g. claim_id), malformed payloads, unparseable amounts/dates, or a schema-version mismatch against CONTROL.DATA_CONTRACT. Each quarantine row keeps the source_table, natural_key, quarantine_reason and quarantine_status (OPEN / RESOLVED / DISCARDED / REPROCESSED) — but the search index exposes only the SUMMARY, never the raw payload (which would be sensitive in a real system). Quarantined records are excluded from certified totals until resolved and reprocessed via CONTROL.REPROCESSING_LEDGER (four-eyes approved).',
      'quarantine,dq,data_contract,ingest,reprocessing,audit'
    ),
    (
      'RB_DQ_FAILURE_01',
      'Quality failures',
      'What does it mean when a data-quality check fails?',
      'dbt tests + DCM checks write results to AUDIT.DATA_QUALITY_RESULT (model_name, test_name, severity WARN/ERROR, status PASS/FAIL/SKIPPED, failed_row_count). Key checks and meanings: assert_no_duplicate_current_claims (the current-version selection produced duplicate claim grains — would double-count dollars); assert_claim_header_line_totals_reconcile (SUM(line paid) != header paid for a claim — allocation/ingest issue); assert_member_months_reconcile (gold_member_months disagrees with fact_eligibility_month — PMPM denominator at risk); assert_eligibility_spans_do_not_overlap (overlapping coverage would inflate member months); assert_claim_line_paid_amount_nonnegative (negative paid outside an adjustment context); assert_late_arrivals_are_captured (the lookback window missed late claims); assert_adjustment_chain_valid (a broken adjustment chain that could mis-state current paid). An ERROR-severity FAIL blocks promotion; a WARN is logged for triage.',
      'dq,tests,reconciliation,failure,severity,audit'
    ),
    (
      'RB_RECONCILIATION_01',
      'Line-to-header reconciliation',
      'How do I check that claim line amounts reconcile to the claim header?',
      'fact_claim_line carries only the current valid version, and patient_responsibility is allocated down to lines so the line sums tie to the header. SUM(paid_amount) per claim_header_sk (or per claim_id) equals the certified header paid; the dbt test assert_claim_header_line_totals_reconcile enforces this invariant. To inspect, GROUP BY claim_id and SUM the line amounts; any non-trivial difference indicates an allocation or ingest defect and should be triaged via the DQ results.',
      'reconciliation,line,header,paid,allocation,test'
    ),
    (
      'RB_GRAIN_01',
      'Grain reference',
      'What is the grain of fact_claim_line and the gold models?',
      'fact_claim_line / gold_claims_semantic_base: one row per claim SERVICE LINE of the current valid claim version. gold_member_months: one row per (payer, plan, month). gold_payer_plan_summary and gold_claim_denial_summary: payer x plan x (...) x month. gold_provider_utilization: (provider, month). gold_condition_cost_summary: (condition_group, month). gold_late_arrival_impact: one row per impacted service month. fact_eligibility_month: one row per (member, payer, plan, covered month). Match your GROUP BY to the question''s grain; if header vs line is ambiguous, clarify before answering.',
      'grain,fact_claim_line,gold,member_months,reference'
    )
) src
ON tgt.doc_id = src.doc_id
WHEN MATCHED THEN UPDATE SET
    topic    = src.topic,
    question = src.question,
    answer   = src.answer,
    tags     = src.tags
WHEN NOT MATCHED THEN INSERT
    (doc_id, topic, question, answer, tags, created_at)
VALUES
    (src.doc_id, src.topic, src.question, src.answer, src.tags, CURRENT_TIMESTAMP());

-- Sanity check (commented):
-- SELECT doc_id, topic FROM SEMANTIC.CLAIMS_RUNBOOK ORDER BY doc_id;
