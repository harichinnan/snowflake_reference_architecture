/* =============================================================================
   semantic_view_claims.sql
   snowflake-claims-platform :: Native Snowflake SEMANTIC VIEW
   -----------------------------------------------------------------------------
   Creates SEMANTIC.CLAIMS_SEMANTIC_VIEW — a first-class Snowflake SEMANTIC VIEW
   over the certified GOLD products + the SILVER_DIMENSIONAL member-month
   denominator. This is the SQL-native twin of the Cortex Analyst YAML model;
   metric math is kept IDENTICAL across both and against SEMANTIC.METRIC_REGISTRY.

   SYNTHETIC DATA. Not real CMS/Medicaid/PHI. All amounts illustrative.

   COLUMN NAMES below match the dbt models EXACTLY:
     gold_claims_semantic_base : fact_claim_line_sk, claim_id, claim_month,
       service_date, payer_sk/plan_sk, payer_name/payer_type, plan_type,
       provider_npi/provider_name/provider_specialty, condition_group,
       primary_diagnosis_code, procedure_code, patient_sk/member_id,
       denial_flag/adjustment_flag/reversal_flag,
       charge_amount/allowed_amount/paid_amount/patient_responsibility/units.
     gold_member_months        : payer_sk, plan_sk, month_start, member_months,
       distinct_members.
     gold_payer_plan_summary   : payer_sk, plan_sk, month_start, total_paid,
       total_allowed, total_charge, claim_count, member_months, pmpm,
       denied_claim_count, denial_rate.
     gold_claim_denial_summary : payer_sk, plan_sk, claim_month, total_claims,
       denied_claims, denial_rate.

   WHAT A SEMANTIC VIEW GIVES YOU
     - Logical TABLES with PRIMARY KEY declarations.
     - RELATIONSHIPS (governed joins) between logical tables.
     - FACTS      : row-level numeric expressions.
     - DIMENSIONS : row-level grouping attributes.
     - METRICS    : aggregating expressions (the certified business metrics).
     Query with the SEMANTIC_VIEW(...) table function:

         SELECT * FROM SEMANTIC_VIEW(
           SEMANTIC.CLAIMS_SEMANTIC_VIEW
             DIMENSIONS claim_line.plan_type, claim_line.claim_month
             METRICS    claim_line.total_paid
         );

   ENVIRONMENT
     Defaults to CLAIMS_PROD. For DEV run with the database set to CLAIMS_DEV.

   GA / SYNTAX CAVEAT
     SEMANTIC VIEW DDL (and specific clauses like cross-table metric ratios) may
     not be GA in every account/region. SECTION A is wrapped in EXECUTE IMMEDIATE
     so a failure does NOT abort the script; SECTION B always creates a GOVERNED
     FALLBACK VIEW (SEMANTIC.CLAIMS_SEMANTIC_VIEW_FALLBACK) exposing the same
     certified metrics at the payer x plan x month grain. Cross-table PMPM is
     defined in the fallback (single SQL view) where it is always valid.

   RUN AS: CLAIMS_SYSADMIN. Idempotent (CREATE OR REPLACE).
   ============================================================================= */

USE ROLE CLAIMS_SYSADMIN;
USE DATABASE CLAIMS_PROD;          -- swap to CLAIMS_DEV for the dev deploy
USE SCHEMA SEMANTIC;

/* =============================================================================
   SECTION A — NATIVE SEMANTIC VIEW (wrapped; no-ops if DDL unsupported)
   -----------------------------------------------------------------------------
   Logical tables:
     claim_line    -> GOLD.GOLD_CLAIMS_SEMANTIC_BASE   (claim-line grain)
     member_months -> GOLD.GOLD_MEMBER_MONTHS          (payer x plan x month)
     payer_plan    -> GOLD.GOLD_PAYER_PLAN_SUMMARY     (payer x plan x month)
     denial        -> GOLD.GOLD_CLAIM_DENIAL_SUMMARY   (payer x plan x ... x month)
   Relationships join the fact and denominators on conformed SURROGATE keys.
   ============================================================================= */
EXECUTE IMMEDIATE $$
BEGIN
  CREATE OR REPLACE SEMANTIC VIEW SEMANTIC.CLAIMS_SEMANTIC_VIEW

    /* ---- Logical tables + primary keys ------------------------------------ */
    TABLES (
      claim_line AS CLAIMS_PROD.GOLD.GOLD_CLAIMS_SEMANTIC_BASE
        PRIMARY KEY (FACT_CLAIM_LINE_SK)
        COMMENT = 'Claim-line grain fact (synthetic).',

      member_months AS CLAIMS_PROD.GOLD.GOLD_MEMBER_MONTHS
        PRIMARY KEY (PAYER_SK, PLAN_SK, MONTH_START)
        COMMENT = 'Member-months by payer x plan x month; PMPM denominator (synthetic).',

      payer_plan AS CLAIMS_PROD.GOLD.GOLD_PAYER_PLAN_SUMMARY
        PRIMARY KEY (PAYER_SK, PLAN_SK, MONTH_START)
        COMMENT = 'Pre-aggregated payer x plan x month financials (synthetic).',

      denial AS CLAIMS_PROD.GOLD.GOLD_CLAIM_DENIAL_SUMMARY
        PRIMARY KEY (PAYER_SK, PLAN_SK, CLAIM_STATUS, DENIAL_REASON_CODE, CLAIM_MONTH)
        COMMENT = 'Denial summary payer x plan x status x reason x month (synthetic).'
    )

    /* ---- Relationships (governed joins) ----------------------------------
       claim_line -> payer_plan and -> member_months on payer_sk/plan_sk/month
       (claim_month <-> month_start). member_months -> payer_plan on the same
       so PMPM pairs numerator + denominator at the correct grain. ----------- */
    RELATIONSHIPS (
      claim_line_to_payer_plan AS
        claim_line (PAYER_SK, PLAN_SK, CLAIM_MONTH)
          REFERENCES payer_plan (PAYER_SK, PLAN_SK, MONTH_START),

      claim_line_to_member_months AS
        claim_line (PAYER_SK, PLAN_SK, CLAIM_MONTH)
          REFERENCES member_months (PAYER_SK, PLAN_SK, MONTH_START),

      mm_to_payer_plan AS
        member_months (PAYER_SK, PLAN_SK, MONTH_START)
          REFERENCES payer_plan (PAYER_SK, PLAN_SK, MONTH_START)
    )

    /* ---- Facts: row-level numeric expressions ----------------------------- */
    FACTS (
      claim_line.f_paid          AS PAID_AMOUNT
        COMMENT = 'Line adjudicated paid amount (synthetic).',
      claim_line.f_allowed       AS ALLOWED_AMOUNT
        COMMENT = 'Line contractually allowed amount (synthetic).',
      claim_line.f_charge        AS CHARGE_AMOUNT
        COMMENT = 'Line billed/submitted amount (synthetic).',
      claim_line.f_patient_resp  AS PATIENT_RESPONSIBILITY
        COMMENT = 'Line member cost share (synthetic).',
      claim_line.f_units         AS UNITS
        COMMENT = 'Service units on the line.',
      member_months.f_member_months AS MEMBER_MONTHS
        COMMENT = 'Member-months for the payer/plan/month.',
      payer_plan.f_pp_paid       AS TOTAL_PAID,
      denial.f_den_total         AS TOTAL_CLAIMS,
      denial.f_den_denied        AS DENIED_CLAIMS
    )

    /* ---- Dimensions: grouping attributes ---------------------------------- */
    DIMENSIONS (
      claim_line.claim_id            AS CLAIM_ID            COMMENT = 'Claim natural key.',
      claim_line.claim_status        AS CLAIM_STATUS        COMMENT = 'Adjudication status.',
      claim_line.claim_type          AS CLAIM_TYPE,
      claim_line.claim_setting       AS CLAIM_SETTING       COMMENT = 'Care setting rollup.',
      claim_line.payer_sk            AS PAYER_SK,
      claim_line.payer_name          AS PAYER_NAME,
      claim_line.payer_type          AS PAYER_TYPE          COMMENT = 'Commercial/Medicare/Medicaid/Other.',
      claim_line.plan_sk             AS PLAN_SK,
      claim_line.plan_type           AS PLAN_TYPE           COMMENT = 'HMO/PPO/EPO/POS (synthetic).',
      claim_line.plan_type_name      AS PLAN_TYPE_NAME,
      claim_line.provider_npi        AS PROVIDER_NPI,
      claim_line.provider_name       AS PROVIDER_NAME,
      claim_line.provider_specialty  AS PROVIDER_SPECIALTY,
      claim_line.provider_state      AS PROVIDER_STATE,
      claim_line.condition_group     AS CONDITION_GROUP,
      claim_line.primary_dx          AS PRIMARY_DIAGNOSIS_CODE,
      claim_line.procedure_code      AS PROCEDURE_CODE,
      claim_line.procedure_category  AS PROCEDURE_CATEGORY,
      claim_line.patient_sk          AS PATIENT_SK,
      claim_line.member_id           AS MEMBER_ID,
      claim_line.age_band            AS AGE_BAND,
      claim_line.gender              AS GENDER,
      claim_line.member_state        AS MEMBER_STATE,
      claim_line.denial_flag         AS DENIAL_FLAG,
      claim_line.adjustment_flag     AS ADJUSTMENT_FLAG,
      claim_line.reversal_flag       AS REVERSAL_FLAG,
      -- time dimensions
      claim_line.claim_month         AS CLAIM_MONTH         COMMENT = 'Default month grain.',
      claim_line.service_date        AS SERVICE_DATE,
      member_months.month_start      AS MONTH_START         COMMENT = 'Coverage month.'
    )

    /* ---- Metrics: certified aggregations ---------------------------------
       Names + math mirror SEMANTIC.METRIC_REGISTRY and the YAML. ------------- */
    METRICS (
      -- Money (line-additive over the fact)
      claim_line.total_paid    AS SUM(claim_line.f_paid)
        COMMENT = 'CERTIFIED total_paid_amount = SUM(paid_amount). Synthetic.',
      claim_line.total_allowed AS SUM(claim_line.f_allowed)
        COMMENT = 'CERTIFIED allowed_amount = SUM(allowed_amount).',
      claim_line.total_charge  AS SUM(claim_line.f_charge)
        COMMENT = 'CERTIFIED charge_amount = SUM(charge_amount).',
      claim_line.total_patient_responsibility AS SUM(claim_line.f_patient_resp)
        COMMENT = 'CERTIFIED patient_responsibility = SUM(patient_responsibility).',

      -- Member months
      member_months.member_months AS SUM(member_months.f_member_months)
        COMMENT = 'CERTIFIED member_months. PMPM denominator.',

      -- PMPM as a cross-table ratio over the mm_to_payer_plan relationship.
      -- NOTE: if cross-table metric expressions are NOT GA in your account, this
      -- metric is the part most likely to fail. The whole CREATE is wrapped, and
      -- the SECTION B fallback view always exposes PMPM. To keep the native view
      -- without PMPM, delete this one metric and re-run.
      payer_plan.pmpm AS
        SUM(payer_plan.f_pp_paid) / NULLIF(SUM(member_months.f_member_months), 0)
        COMMENT = 'CERTIFIED pmpm = total paid / member months. Synthetic.',

      -- Denial rate (recomputed from counts, NOT an average of a rate column).
      denial.denial_rate AS
        SUM(denial.f_den_denied) / NULLIF(SUM(denial.f_den_total), 0)
        COMMENT = 'CERTIFIED denial_rate = denied/total claims.',

      -- Distinct members (= distinct patients)
      claim_line.distinct_members AS COUNT(DISTINCT claim_line.member_id)
        COMMENT = 'CERTIFIED distinct_members = COUNT(DISTINCT member_id).',

      -- Volume + lifecycle
      claim_line.claims_volume AS COUNT(DISTINCT claim_line.claim_id)
        COMMENT = 'CERTIFIED claims_volume = COUNT(DISTINCT claim_id).',
      claim_line.adjustment_count AS
        COUNT(DISTINCT CASE WHEN claim_line.adjustment_flag THEN claim_line.claim_id END)
        COMMENT = 'CERTIFIED adjustment_count.',
      claim_line.reversal_count AS
        COUNT(DISTINCT CASE WHEN claim_line.reversal_flag THEN claim_line.claim_id END)
        COMMENT = 'CERTIFIED reversal_count.'
    )

    COMMENT = 'Governed semantic view for synthetic claims platform. Certified metrics: TOTAL_PAID, PMPM, MEMBER_MONTHS, DENIAL_RATE, DISTINCT_MEMBERS. SYNTHETIC — no real PHI.';

  -- Read grants (semantic-view object type).
  GRANT SELECT ON SEMANTIC VIEW SEMANTIC.CLAIMS_SEMANTIC_VIEW TO ROLE CLAIMS_ANALYST;
  GRANT SELECT ON SEMANTIC VIEW SEMANTIC.CLAIMS_SEMANTIC_VIEW TO ROLE CLAIMS_MCP_READER;
  SYSTEM$LOG('info', 'CLAIMS_SEMANTIC_VIEW (native SEMANTIC VIEW) created.');
EXCEPTION
  WHEN OTHER THEN
    SYSTEM$LOG('warn',
      'Native SEMANTIC VIEW DDL unavailable or a clause not GA; relying on ' ||
      'SEMANTIC.CLAIMS_SEMANTIC_VIEW_FALLBACK (Section B). Error: ' || SQLERRM);
END;
$$;

/* Example queries (commented):
   -- Total paid + PMPM by plan type and month:
   --   SELECT * FROM SEMANTIC_VIEW(
   --     SEMANTIC.CLAIMS_SEMANTIC_VIEW
   --       DIMENSIONS claim_line.plan_type, claim_line.claim_month
   --       METRICS    claim_line.total_paid, member_months.member_months, payer_plan.pmpm);
   -- Denial rate by payer:
   --   SELECT * FROM SEMANTIC_VIEW(
   --     SEMANTIC.CLAIMS_SEMANTIC_VIEW
   --       DIMENSIONS claim_line.payer_name METRICS denial.denial_rate, claim_line.claims_volume);
*/

/* =============================================================================
   SECTION B — GOVERNED FALLBACK VIEW (always created)
   -----------------------------------------------------------------------------
   Plain SQL view exposing the same certified metrics + a pre-computed PMPM /
   denial_rate at the common payer x plan x month grain, so consumers keep
   working when the native SEMANTIC VIEW (or a clause) is unavailable. PMPM is
   computed here where cross-table ratios are always valid.
   ============================================================================= */
CREATE OR REPLACE VIEW SEMANTIC.CLAIMS_SEMANTIC_VIEW_FALLBACK
  COMMENT = 'Fallback governed view (synthetic). Mirrors CLAIMS_SEMANTIC_VIEW certified metrics at payer x plan x month grain.'
AS
WITH pp AS (
  SELECT payer_sk, payer_name, payer_type, plan_sk, plan_type, plan_type_name,
         month_start,
         SUM(total_paid)     AS total_paid_amount,
         SUM(total_allowed)  AS total_allowed_amount,
         SUM(total_charge)   AS total_charge_amount,
         SUM(claim_count)    AS claims_volume,
         SUM(member_months)  AS member_months
  FROM CLAIMS_PROD.GOLD.GOLD_PAYER_PLAN_SUMMARY
  GROUP BY payer_sk, payer_name, payer_type, plan_sk, plan_type, plan_type_name, month_start
),
den AS (
  SELECT payer_sk, plan_sk, claim_month,
         SUM(total_claims)   AS total_claims,
         SUM(denied_claims)  AS denied_claims
  FROM CLAIMS_PROD.GOLD.GOLD_CLAIM_DENIAL_SUMMARY
  GROUP BY payer_sk, plan_sk, claim_month
)
SELECT
    pp.payer_sk,
    pp.payer_name,
    pp.payer_type,
    pp.plan_sk,
    pp.plan_type,
    pp.plan_type_name,
    pp.month_start,
    pp.total_paid_amount,
    pp.total_allowed_amount,
    pp.total_charge_amount,
    pp.claims_volume,
    pp.member_months,
    pp.total_paid_amount / NULLIF(pp.member_months, 0)        AS pmpm,
    den.total_claims,
    den.denied_claims,
    den.denied_claims / NULLIF(den.total_claims, 0)           AS denial_rate
FROM pp
LEFT JOIN den
  ON pp.payer_sk = den.payer_sk
 AND pp.plan_sk  = den.plan_sk
 AND pp.month_start = den.claim_month;

GRANT SELECT ON VIEW SEMANTIC.CLAIMS_SEMANTIC_VIEW_FALLBACK TO ROLE CLAIMS_ANALYST;
GRANT SELECT ON VIEW SEMANTIC.CLAIMS_SEMANTIC_VIEW_FALLBACK TO ROLE CLAIMS_MCP_READER;

/* DONE. */
