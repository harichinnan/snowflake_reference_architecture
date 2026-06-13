/* =============================================================================
   metric_registry_seed.sql
   snowflake-claims-platform :: Certified metric registry seed
   -----------------------------------------------------------------------------
   Populates SEMANTIC.METRIC_REGISTRY with the CERTIFIED metric definitions and
   mirrors them to CONTROL.SEMANTIC_METRIC_REGISTRY (the governance/control-plane
   copy CI uses to detect drift between the registry, the SEMANTIC VIEW and the
   Cortex Analyst YAML).

   SYNTHETIC DATA. Not real CMS/Medicaid/PHI. Definitions describe synthetic
   measures only.

   calculation_sql + source_model reference the ACTUAL gold model columns:
     gold_claims_semantic_base : paid_amount, allowed_amount, charge_amount,
       patient_responsibility, member_id, claim_id, adjustment_flag, reversal_flag
     gold_payer_plan_summary   : total_paid, member_months
     gold_member_months        : member_months
     gold_claim_denial_summary : denied_claims, total_claims

   SCHEMA (assumed; see snowflake/setup/012):
     METRIC_REGISTRY(metric_name, business_definition, calculation_sql, grain,
       owner, certified_status, source_model, allowed_dimensions VARIANT,
       default_filters VARIANT, created_at, updated_at)

   IDEMPOTENT: MERGE upserts by metric_name. Run as CLAIMS_SYSADMIN.
   ============================================================================= */

USE ROLE CLAIMS_SYSADMIN;
USE DATABASE CLAIMS_PROD;          -- swap to CLAIMS_DEV for the dev deploy
USE SCHEMA SEMANTIC;

-- Defensive create (no-op if setup/012 already made it).
CREATE TABLE IF NOT EXISTS SEMANTIC.METRIC_REGISTRY (
    metric_name          STRING,
    business_definition  STRING,
    calculation_sql      STRING,
    grain                STRING,
    owner                STRING,
    certified_status     STRING,
    source_model         STRING,
    allowed_dimensions   VARIANT,
    default_filters      VARIANT,
    created_at           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    updated_at           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

/* -----------------------------------------------------------------------------
   Upsert certified metrics. allowed_dimensions/default_filters are VARIANT
   arrays/objects built with PARSE_JSON so the seed is portable.
   --------------------------------------------------------------------------- */
MERGE INTO SEMANTIC.METRIC_REGISTRY tgt
USING (
    SELECT column1 AS metric_name,
           column2 AS business_definition,
           column3 AS calculation_sql,
           column4 AS grain,
           column5 AS owner,
           column6 AS certified_status,
           column7 AS source_model,
           PARSE_JSON(column8) AS allowed_dimensions,
           PARSE_JSON(column9) AS default_filters
    FROM VALUES
    (
      'total_paid_amount',
      'Total adjudicated amount the payer paid for the current valid version of each claim. The default meaning of "cost"/"spend". SYNTHETIC; not real claims payments.',
      'SUM(paid_amount)',
      'claim service line (rolls up to any dimension)',
      'semantic_layer_owner',
      'CERTIFIED',
      'GOLD.gold_claims_semantic_base',
      '["payer_name","payer_type","plan_type","provider_specialty","condition_group","claim_setting","claim_status","claim_month"]',
      '{}'
    ),
    (
      'allowed_amount',
      'Total contractually allowed amount (allowed = paid + patient_responsibility). SYNTHETIC.',
      'SUM(allowed_amount)',
      'claim service line',
      'semantic_layer_owner',
      'CERTIFIED',
      'GOLD.gold_claims_semantic_base',
      '["payer_name","plan_type","provider_specialty","condition_group","claim_month"]',
      '{}'
    ),
    (
      'charge_amount',
      'Total billed/submitted amount (gross charge). NOT what was paid. SYNTHETIC.',
      'SUM(charge_amount)',
      'claim service line',
      'semantic_layer_owner',
      'CERTIFIED',
      'GOLD.gold_claims_semantic_base',
      '["payer_name","plan_type","provider_specialty","condition_group","claim_month"]',
      '{}'
    ),
    (
      'patient_responsibility',
      'Total member cost share (copay + coinsurance + deductible), line-allocated from the header in proportion to line allowed. SYNTHETIC.',
      'SUM(patient_responsibility)',
      'claim service line',
      'semantic_layer_owner',
      'CERTIFIED',
      'GOLD.gold_claims_semantic_base',
      '["payer_name","plan_type","age_band","condition_group","claim_month"]',
      '{}'
    ),
    (
      'pmpm',
      'Per member per month paid = total paid / member months. Numerator total_paid from gold_payer_plan_summary; denominator member_months from gold_member_months, joined on payer_sk/plan_sk/month. SYNTHETIC.',
      'SUM(total_paid) / NULLIF(SUM(member_months), 0)',
      'payer x plan x month (or rolled up by plan_type x month)',
      'semantic_layer_owner',
      'CERTIFIED',
      'GOLD.gold_payer_plan_summary + GOLD.gold_member_months',
      '["payer_name","payer_type","plan_type","month_start"]',
      '{}'
    ),
    (
      'member_months',
      'Total member-months of coverage (the PMPM denominator). One member-month per covered member per month. SEMI-additive: do not double-count across overlapping spans. SYNTHETIC.',
      'SUM(member_months)',
      'payer x plan x month',
      'semantic_layer_owner',
      'CERTIFIED',
      'GOLD.gold_member_months',
      '["payer_name","payer_type","plan_type","month_start"]',
      '{}'
    ),
    (
      'distinct_members',
      'Distinct members with at least one claim. "members" means distinct patients (member_id), not rows or claims. SEMI-additive across months. SYNTHETIC.',
      'COUNT(DISTINCT member_id)',
      'claim service line (counted distinct)',
      'semantic_layer_owner',
      'CERTIFIED',
      'GOLD.gold_claims_semantic_base',
      '["plan_type","payer_name","condition_group","provider_specialty","claim_month"]',
      '{}'
    ),
    (
      'denial_rate',
      'Denied claims divided by total claims, recomputed from counts (do NOT average a pre-computed rate column). SYNTHETIC.',
      'SUM(denied_claims) / NULLIF(SUM(total_claims), 0)',
      'payer x plan x status x reason x month',
      'semantic_layer_owner',
      'CERTIFIED',
      'GOLD.gold_claim_denial_summary',
      '["payer_name","plan_type","claim_status","denial_reason","claim_month"]',
      '{}'
    ),
    (
      'adjustment_count',
      'Count of distinct claims whose adjustment chain contains an adjustment (replacement of a prior version). Helps explain why prior-month paid restates. SYNTHETIC.',
      'COUNT(DISTINCT CASE WHEN adjustment_flag THEN claim_id END)',
      'claim (counted distinct)',
      'semantic_layer_owner',
      'CERTIFIED',
      'GOLD.gold_claims_semantic_base',
      '["payer_name","plan_type","claim_month"]',
      '{}'
    ),
    (
      'reversal_count',
      'Count of distinct claims whose chain contains a reversal/void (backing out a prior version). SYNTHETIC.',
      'COUNT(DISTINCT CASE WHEN reversal_flag THEN claim_id END)',
      'claim (counted distinct)',
      'semantic_layer_owner',
      'CERTIFIED',
      'GOLD.gold_claims_semantic_base',
      '["payer_name","plan_type","claim_month"]',
      '{}'
    ),
    (
      'claims_volume',
      'Distinct claims (header grain). The default meaning of "claims"/"volume". SYNTHETIC.',
      'COUNT(DISTINCT claim_id)',
      'claim (counted distinct)',
      'semantic_layer_owner',
      'CERTIFIED',
      'GOLD.gold_claims_semantic_base',
      '["claim_status","plan_type","payer_name","claim_setting","claim_month"]',
      '{}'
    )
) src
ON tgt.metric_name = src.metric_name
WHEN MATCHED THEN UPDATE SET
    business_definition = src.business_definition,
    calculation_sql     = src.calculation_sql,
    grain               = src.grain,
    owner               = src.owner,
    certified_status    = src.certified_status,
    source_model        = src.source_model,
    allowed_dimensions  = src.allowed_dimensions,
    default_filters     = src.default_filters,
    updated_at          = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT
    (metric_name, business_definition, calculation_sql, grain, owner,
     certified_status, source_model, allowed_dimensions, default_filters,
     created_at, updated_at)
VALUES
    (src.metric_name, src.business_definition, src.calculation_sql, src.grain,
     src.owner, src.certified_status, src.source_model, src.allowed_dimensions,
     src.default_filters, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());

/* -----------------------------------------------------------------------------
   Mirror to the control-plane copy used by CI for drift detection.
   Same column set; created defensively in case CONTROL hasn't seeded it.
   --------------------------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS CONTROL.SEMANTIC_METRIC_REGISTRY (
    metric_name          STRING,
    business_definition  STRING,
    calculation_sql      STRING,
    grain                STRING,
    owner                STRING,
    certified_status     STRING,
    source_model         STRING,
    allowed_dimensions   VARIANT,
    default_filters      VARIANT,
    created_at           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    updated_at           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

MERGE INTO CONTROL.SEMANTIC_METRIC_REGISTRY tgt
USING SEMANTIC.METRIC_REGISTRY src
ON tgt.metric_name = src.metric_name
WHEN MATCHED THEN UPDATE SET
    business_definition = src.business_definition,
    calculation_sql     = src.calculation_sql,
    grain               = src.grain,
    owner               = src.owner,
    certified_status    = src.certified_status,
    source_model        = src.source_model,
    allowed_dimensions  = src.allowed_dimensions,
    default_filters     = src.default_filters,
    updated_at          = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT
    (metric_name, business_definition, calculation_sql, grain, owner,
     certified_status, source_model, allowed_dimensions, default_filters,
     created_at, updated_at)
VALUES
    (src.metric_name, src.business_definition, src.calculation_sql, src.grain,
     src.owner, src.certified_status, src.source_model, src.allowed_dimensions,
     src.default_filters, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());

-- Sanity check (commented):
-- SELECT metric_name, certified_status, grain FROM SEMANTIC.METRIC_REGISTRY ORDER BY metric_name;
