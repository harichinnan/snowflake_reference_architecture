/* =============================================================================
   data_dictionary_seed.sql
   snowflake-claims-platform :: Data dictionary seed
   -----------------------------------------------------------------------------
   Populates SEMANTIC.DATA_DICTIONARY with plain-language descriptions of key
   tables and columns so Cortex Search (CLAIMS_METRIC_DOC_SEARCH) can answer
   "what does paid amount mean?", "what is the grain of fact_claim_line?",
   "paid vs allowed vs charge?", "what is a condition group?", etc.

   SYNTHETIC DATA. Not real CMS/Medicaid/PHI.

   SCHEMA (assumed; aligns with snowflake/setup/012 + the Cortex Search query):
     DATA_DICTIONARY(object_name, column_name, description, data_type, notes,
       is_pii, created_at)
   A NULL column_name means the row describes the TABLE/grain itself.
   is_pii flags columns that would be PII in a real system (synthetic here).

   IDEMPOTENT: deletes the seeded object rows then reinserts. Run as CLAIMS_SYSADMIN.
   ============================================================================= */

USE ROLE CLAIMS_SYSADMIN;
USE DATABASE CLAIMS_PROD;          -- swap to CLAIMS_DEV for the dev deploy
USE SCHEMA SEMANTIC;

-- Defensive create (no-op if setup/012 already made it). Add notes/is_pii if
-- the deployed table predates them.
CREATE TABLE IF NOT EXISTS SEMANTIC.DATA_DICTIONARY (
    object_name  STRING,
    column_name  STRING,
    description  STRING,
    data_type    STRING,
    notes        STRING,
    is_pii       BOOLEAN DEFAULT FALSE,
    created_at   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Reload deterministically (idempotent reseed of the documented objects).
DELETE FROM SEMANTIC.DATA_DICTIONARY
WHERE object_name IN (
  'GOLD.gold_claims_semantic_base','GOLD.gold_member_months',
  'GOLD.gold_payer_plan_summary','GOLD.gold_claim_denial_summary',
  'GOLD.gold_condition_cost_summary','GOLD.gold_provider_utilization',
  'GOLD.gold_late_arrival_impact','SILVER_DIMENSIONAL.fact_claim_line',
  'SILVER_DIMENSIONAL.fact_eligibility_month','SILVER_DIMENSIONAL.fact_claim_adjustment',
  'CONCEPT.amounts','CONCEPT.member_months','CONCEPT.condition_group',
  'CONCEPT.denial','CONCEPT.adjustment_reversal'
);

INSERT INTO SEMANTIC.DATA_DICTIONARY (object_name, column_name, description, data_type, notes, is_pii)
SELECT column1, column2, column3, column4, column5, column6
FROM VALUES
  -- ===== TABLE-level / grain descriptions =====================================
  ('GOLD.gold_claims_semantic_base', NULL,
   'Primary CERTIFIED semantic fact at the claim-LINE grain (one row per service line of the current valid claim version), denormalized with payer/plan/provider/condition/member/procedure/date attributes and line-additive money. Backs the semantic view and Cortex Analyst.',
   NULL, 'Grain: one row per fact_claim_line_sk. SUM(paid_amount) per claim_id = certified header paid.', FALSE),
  ('SILVER_DIMENSIONAL.fact_claim_line', NULL,
   'Star-schema transactional fact: ONE ROW PER SERVICE LINE OF THE CURRENT VALID VERSION OF A CLAIM. Superseded/adjusted-away versions are excluded so dollars are not double-counted; flags show that a claim was adjusted/reversed. Carries charge/allowed/paid/patient_responsibility/units.',
   NULL, 'Grain: one row per (claim_id, claim_line_id, claim_version=current). FK keys: patient_sk, provider_sk, payer_sk, plan_sk, date_sk, procedure_sk. SUM(line.paid)=header.paid is a reconciliation invariant (tested).', FALSE),
  ('SILVER_DIMENSIONAL.fact_claim_adjustment', NULL,
   'Event/accumulating-history fact: one row per claim lifecycle event (ADJUSTMENT, VOID, REVERSAL, PAY). Explains HOW a claim''s paid moved over time via paid_amount_delta. fact_claim_line holds only current truth; this holds the deltas that produced it.',
   NULL, 'Grain: one row per (claim_id, claim_version, event_seq). SUM(paid_amount_delta) over a claim''s chain ties to its current paid.', FALSE),
  ('SILVER_DIMENSIONAL.fact_eligibility_month', NULL,
   'Member-month coverage fact: one row per (member, payer, plan, covered calendar month). The authoritative eligibility spine feeding gold_member_months and the PMPM denominator. A partial month of coverage counts as one member month.',
   NULL, 'Grain: one row per (member_id, payer_id, plan_id, month_start). member_month_flag = 1 always; SUM = member months. De-duped so overlapping spans do not inflate.', FALSE),
  ('GOLD.gold_member_months', NULL,
   'CERTIFIED PMPM DENOMINATOR. Pre-aggregated to (payer, plan, month) with member_months and distinct_members. NOT member-level rows.',
   NULL, 'Grain: (payer_sk, plan_sk, month_start). member_months is additive across months; distinct_members is semi-additive (do not sum across months).', FALSE),
  ('GOLD.gold_payer_plan_summary', NULL,
   'CERTIFIED payer P&L + PMPM. Paid/allowed/charge, claim counts, member_months, certified pmpm and denial_rate by (payer, plan, month). PMPM joins certified paid to member_months on payer/plan/month.',
   NULL, 'Grain: (payer_sk, plan_sk, month_start). pmpm = total_paid / member_months (NULL when member_months = 0).', FALSE),
  ('GOLD.gold_claim_denial_summary', NULL,
   'CERTIFIED denial product. Total vs denied claims, certified denial_rate, and denial reasons by (payer, plan, status, reason, month). Rows with denial_reason = "Not Denied" are the clean-claim slice.',
   NULL, 'Grain: (payer_sk, plan_sk, claim_status, denial_reason_code, claim_month). denial_rate = denied_claims / total_claims per partition.', FALSE),
  ('GOLD.gold_condition_cost_summary', NULL,
   'CERTIFIED cost-by-condition product. Total paid, distinct members WITH the condition, cost per member, and top procedure categories by (condition_group, month). Answers "how many unique members have diabetes?".',
   NULL, 'Grain: (condition_group, claim_month). condition_group from PRIMARY diagnosis. distinct_members_with_condition is semi-additive.', FALSE),
  ('GOLD.gold_provider_utilization', NULL,
   'CERTIFIED provider utilization. Claim/line volume, paid/allowed, distinct members and per-member rates by (provider, month) with specialty and state.',
   NULL, 'Grain: (provider_sk, month_start). paid_per_member = total_paid / distinct_members.', FALSE),
  ('GOLD.gold_late_arrival_impact', NULL,
   'CERTIFIED late-arrival explainability. Splits a month''s paid into original (on-time) vs late (arrived after the month closed) vs restated (current total). Explains why a prior month''s paid changed after first load.',
   NULL, 'Grain: one row per impacted_period (service month). restated_paid = original_paid + late_paid.', FALSE),

  -- ===== gold_claims_semantic_base columns ====================================
  ('GOLD.gold_claims_semantic_base', 'fact_claim_line_sk',
   'Surrogate key of the claim service line (this row''s grain).', 'STRING', 'Hash of (claim_id, claim_line_id, claim_version).', FALSE),
  ('GOLD.gold_claims_semantic_base', 'claim_id',
   'Natural key of the claim (header). A claim has 1..N service lines.', 'STRING', 'Use COUNT(DISTINCT claim_id) for claims_volume.', FALSE),
  ('GOLD.gold_claims_semantic_base', 'claim_header_sk',
   'Surrogate key of the claim header (one per claim_id).', 'STRING', 'SUM(paid_amount) per claim_header_sk = certified header paid.', FALSE),
  ('GOLD.gold_claims_semantic_base', 'claim_month',
   'Month the claim is attributed to (first day of service month). DEFAULT month grain.', 'DATE', 'date_trunc(month, service_from_date). Prefer over service_date unless asked.', FALSE),
  ('GOLD.gold_claims_semantic_base', 'service_date',
   'Date of service (line service-from date).', 'DATE', NULL, FALSE),
  ('GOLD.gold_claims_semantic_base', 'charge_amount',
   'Billed/submitted amount on the line (gross charge). NOT what was paid.', 'NUMBER', 'charge >= allowed >= paid generally. Additive.', FALSE),
  ('GOLD.gold_claims_semantic_base', 'allowed_amount',
   'Contractually allowed amount on the line. allowed = paid + patient_responsibility.', 'NUMBER', 'Additive.', FALSE),
  ('GOLD.gold_claims_semantic_base', 'paid_amount',
   'Adjudicated amount the payer paid on the line (current valid version). The DEFAULT meaning of "cost"/"spend".', 'NUMBER', 'Certified total_paid_amount = SUM(paid_amount). Additive.', FALSE),
  ('GOLD.gold_claims_semantic_base', 'patient_responsibility',
   'Member cost share (copay + coinsurance + deductible), line-allocated from the header in proportion to line allowed.', 'NUMBER', 'Additive; reconciles to header patient responsibility.', FALSE),
  ('GOLD.gold_claims_semantic_base', 'units',
   'Service units billed on the line.', 'NUMBER', 'Additive.', FALSE),
  ('GOLD.gold_claims_semantic_base', 'member_id',
   'Synthetic member identifier. "members" = COUNT(DISTINCT member_id).', 'STRING', 'Would be PII in a real system; synthetic here.', TRUE),
  ('GOLD.gold_claims_semantic_base', 'patient_sk',
   'Member/patient surrogate key.', 'STRING', 'Hash of member_id.', FALSE),
  ('GOLD.gold_claims_semantic_base', 'payer_sk',
   'Payer surrogate key. JOIN key to payer/plan summaries.', 'STRING', NULL, FALSE),
  ('GOLD.gold_claims_semantic_base', 'payer_name',
   'Synthetic payer display name.', 'STRING', NULL, FALSE),
  ('GOLD.gold_claims_semantic_base', 'payer_type',
   'Payer line of business: Commercial/Medicare/Medicaid/Other (synthetic).', 'STRING', NULL, FALSE),
  ('GOLD.gold_claims_semantic_base', 'plan_sk',
   'Plan surrogate key. JOIN key to plan/PMPM summaries.', 'STRING', NULL, FALSE),
  ('GOLD.gold_claims_semantic_base', 'plan_type',
   'Plan/product type code (synthetic, e.g. HMO/PPO/EPO/POS).', 'STRING', NULL, FALSE),
  ('GOLD.gold_claims_semantic_base', 'provider_npi',
   'Synthetic rendering provider NPI.', 'STRING', 'Fabricated; not a real NPI.', FALSE),
  ('GOLD.gold_claims_semantic_base', 'provider_specialty',
   'Rendering provider specialty.', 'STRING', NULL, FALSE),
  ('GOLD.gold_claims_semantic_base', 'condition_group',
   'Clinical condition grouper rolled up from the PRIMARY diagnosis (e.g. Diabetes, CHF, Behavioral Health). "Ungrouped" when no primary diagnosis.', 'STRING', 'Use for "unique members with <condition>" questions.', FALSE),
  ('GOLD.gold_claims_semantic_base', 'primary_diagnosis_code',
   'Primary (position 1) diagnosis code of the claim (synthetic code set).', 'STRING', 'Attached via bridge_claim_diagnosis without fanning the line grain.', FALSE),
  ('GOLD.gold_claims_semantic_base', 'procedure_code',
   'Procedure/service code on the line (synthetic code set).', 'STRING', NULL, FALSE),
  ('GOLD.gold_claims_semantic_base', 'claim_status',
   'Adjudication status of the claim (paid/denied/pending, synthetic codes).', 'STRING', NULL, FALSE),
  ('GOLD.gold_claims_semantic_base', 'claim_setting',
   'Care setting rollup derived from claim_type: Inpatient/Outpatient/Professional/Facility/Pharmacy/Other.', 'STRING', NULL, FALSE),
  ('GOLD.gold_claims_semantic_base', 'denial_flag',
   'TRUE when the line/claim was denied. Drives denial_rate.', 'BOOLEAN', NULL, FALSE),
  ('GOLD.gold_claims_semantic_base', 'denial_reason_code',
   'Denial reason code (NULL when not denied).', 'STRING', 'Resolved to denial_reason in gold_claim_denial_summary.', FALSE),
  ('GOLD.gold_claims_semantic_base', 'adjustment_flag',
   'TRUE when this claim''s adjustment chain contains an adjustment (replacement of a prior version).', 'BOOLEAN', 'Drives adjustment_count. Does not change current dollars (only current version is present).', FALSE),
  ('GOLD.gold_claims_semantic_base', 'reversal_flag',
   'TRUE when this claim''s chain contains a reversal/void (backing out a prior version).', 'BOOLEAN', 'Drives reversal_count.', FALSE),

  -- ===== gold_member_months columns ===========================================
  ('GOLD.gold_member_months', 'member_months',
   'Certified member-month count for the (payer, plan, month). The PMPM denominator.', 'NUMBER', 'SUM(member_month_flag) from fact_eligibility_month. Additive across months.', FALSE),
  ('GOLD.gold_member_months', 'distinct_members',
   'Distinct members covered in the month.', 'NUMBER', 'SEMI-additive: do not sum across months for a unique total.', FALSE),
  ('GOLD.gold_member_months', 'month_start',
   'Calendar month of coverage (first day of month).', 'DATE', 'Join key to claim_month on the claims side.', FALSE),

  -- ===== gold_payer_plan_summary columns ======================================
  ('GOLD.gold_payer_plan_summary', 'total_paid',
   'Certified total paid for the payer/plan/month.', 'NUMBER', 'SUM(paid_amount). PMPM numerator.', FALSE),
  ('GOLD.gold_payer_plan_summary', 'member_months',
   'Member months joined from gold_member_months (PMPM denominator).', 'NUMBER', NULL, FALSE),
  ('GOLD.gold_payer_plan_summary', 'pmpm',
   'CERTIFIED PMPM = total_paid / member_months. NULL only where member_months = 0.', 'NUMBER', 'Recompute SUM(total_paid)/SUM(member_months) when aggregating across rows.', FALSE),
  ('GOLD.gold_payer_plan_summary', 'denial_rate',
   'Denied claims / claim_count for the payer/plan/month.', 'NUMBER', NULL, FALSE),

  -- ===== gold_claim_denial_summary columns ====================================
  ('GOLD.gold_claim_denial_summary', 'total_claims',
   'Total distinct claims in the slice (denominator of denial_rate).', 'NUMBER', NULL, FALSE),
  ('GOLD.gold_claim_denial_summary', 'denied_claims',
   'Distinct denied claims in the slice (numerator of denial_rate).', 'NUMBER', NULL, FALSE),
  ('GOLD.gold_claim_denial_summary', 'denial_rate',
   'CERTIFIED denial_rate = denied_claims / total_claims per partition.', 'NUMBER', 'Recompute from counts when aggregating; do not average.', FALSE),
  ('GOLD.gold_claim_denial_summary', 'denial_reason',
   'Human-readable denial reason. "Not Denied" for clean claims; "Unspecified" when denied but no reason code.', 'STRING', NULL, FALSE),

  -- ===== gold_condition_cost_summary columns ==================================
  ('GOLD.gold_condition_cost_summary', 'distinct_members_with_condition',
   'Unique members attributed to the condition that month (answers "unique members with diabetes").', 'NUMBER', 'SEMI-additive across months; for an all-time unique count, count distinct member_id from the base.', FALSE),
  ('GOLD.gold_condition_cost_summary', 'paid_per_member',
   'total_paid / distinct_members_with_condition for the condition-month.', 'NUMBER', NULL, FALSE),
  ('GOLD.gold_condition_cost_summary', 'top_procedures',
   'Array of the top-5 procedure categories by paid for the condition-month.', 'ARRAY', NULL, FALSE),

  -- ===== gold_provider_utilization columns ====================================
  ('GOLD.gold_provider_utilization', 'claims',
   'Distinct claims for the provider/month.', 'NUMBER', NULL, FALSE),
  ('GOLD.gold_provider_utilization', 'distinct_members',
   'Distinct members seen by the provider that month.', 'NUMBER', 'Semi-additive across months.', FALSE),
  ('GOLD.gold_provider_utilization', 'paid_per_member',
   'total_paid / distinct_members for the provider/month.', 'NUMBER', NULL, FALSE),

  -- ===== gold_late_arrival_impact columns =====================================
  ('GOLD.gold_late_arrival_impact', 'original_paid',
   'Paid excluding late-arriving claims (what the month first showed at close).', 'NUMBER', NULL, FALSE),
  ('GOLD.gold_late_arrival_impact', 'late_paid',
   'Paid added by claims that arrived after the month closed.', 'NUMBER', NULL, FALSE),
  ('GOLD.gold_late_arrival_impact', 'restated_paid',
   'Current certified total = original_paid + late_paid (matches fact_claim_line).', 'NUMBER', NULL, FALSE),
  ('GOLD.gold_late_arrival_impact', 'paid_pct_change',
   'late_paid / original_paid — the percent the month moved after close.', 'NUMBER', NULL, FALSE),

  -- ===== CONCEPT rows (cross-cutting definitions) =============================
  ('CONCEPT.amounts', NULL,
   'paid vs allowed vs charge: CHARGE = billed/submitted (gross); ALLOWED = contractually allowed (allowed = paid + patient_responsibility); PAID = what the payer actually paid. "cost"/"spend" default to PAID. SYNTHETIC.',
   NULL, 'charge >= allowed >= paid in general. Patient responsibility = allowed - paid.', FALSE),
  ('CONCEPT.member_months', NULL,
   'A member month is one month of coverage for one member. SUM(member_months) is the PMPM denominator. A partial month counts as one (any-day-in-month convention).',
   NULL, 'Semi-additive concept for distinct members; additive for member_months.', FALSE),
  ('CONCEPT.condition_group', NULL,
   'A condition group buckets the PRIMARY diagnosis into a clinical grouper (e.g. Diabetes). "How many members have diabetes" = distinct members where condition_group matches.',
   NULL, 'Attribution uses position-1 primary diagnosis to avoid fanning the line grain.', FALSE),
  ('CONCEPT.denial', NULL,
   'A denial means a claim/line was not paid for an adjudication reason. denial_rate = denied_claims / total_claims, recomputed from counts (never averaged).',
   NULL, NULL, FALSE),
  ('CONCEPT.adjustment_reversal', NULL,
   'An ADJUSTMENT replaces a prior claim version with corrected amounts; a REVERSAL/VOID backs out a prior version. fact_claim_line keeps only the CURRENT valid version so dollars are not double-counted; flags + fact_claim_adjustment preserve the history.',
   NULL, 'This is why a prior month''s paid can change after first load (see late_arrival_impact).', FALSE);

-- Sanity check (commented):
-- SELECT object_name, COUNT(*) FROM SEMANTIC.DATA_DICTIONARY GROUP BY 1 ORDER BY 1;
