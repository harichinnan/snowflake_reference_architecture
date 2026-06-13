# Snowflake Workbooks

Interactive exploration of the synthetic claims platform using **Snowflake Workbooks** — SQL + charts directly in Snowflake, no external BI tool (consistent with the single-vendor constraint). Workbooks read the certified `GOLD`/`SEMANTIC` layers using `WH_CLAIMS_ANALYST` and role `CLAIMS_ANALYST`.

> ⚠️ **Synthetic data.** Not real CMS/Medicare/Medicaid/PHI.

---

## 1. Setup

1. In Snowsight, create a new **Workbook**.
2. Set context: role `CLAIMS_ANALYST`, warehouse `WH_CLAIMS_ANALYST`, database `CLAIMS_PROD` (or `CLAIMS_DEV`), schema `GOLD`.
3. Add one **section** per analysis below; each section has one or more SQL **cells** plus a **chart**.
4. Prefer querying `GOLD`/`SEMANTIC` (certified) so numbers match Cortex Analyst.

```sql
USE ROLE CLAIMS_ANALYST;
USE WAREHOUSE WH_CLAIMS_ANALYST;
USE DATABASE CLAIMS_PROD;
USE SCHEMA GOLD;
```

---

## 2. Sections

### 2.1 Claims Volume Overview
```sql
SELECT DATE_TRUNC('month', service_start_dt) AS month, COUNT(*) AS claim_count
FROM SILVER_DIMENSIONAL.FACT_CLAIM_HEADER
GROUP BY 1 ORDER BY 1;
```
**Chart:** column chart, month vs claim_count. **Explore:** split by `claim_type`, by `payer_id`.

### 2.2 Paid Amount Trend
```sql
SELECT month, total_paid
FROM GOLD.CLAIMS_MONTHLY
ORDER BY month;
```
**Chart:** line chart of total_paid over time. **Explore:** overlay `total_charge`; compute paid/charge ratio; isolate late-arrival contribution.

### 2.3 Payer/Plan PMPM
```sql
SELECT month, plan_type, pmpm
FROM GOLD.PMPM_BY_PLAN
ORDER BY month, plan_type;
```
**Chart:** multi-line, one line per `plan_type`. **Explore:** decompose PMPM into paid vs member_months; compare HMO/PPO/etc.

### 2.4 Provider Utilization
```sql
SELECT provider_npi, SUM(claim_count) AS claims, SUM(paid_amount) AS paid
FROM GOLD.PROVIDER_UTILIZATION
GROUP BY 1 ORDER BY paid DESC LIMIT 25;
```
**Chart:** bar chart top-N providers. **Explore:** join `DIM_PROVIDER` for specialty; paid-per-claim outliers.

### 2.5 Condition Cost Summary
```sql
SELECT month, condition, paid_amount, cost_per_member
FROM GOLD.CONDITION_COST
ORDER BY paid_amount DESC;
```
**Chart:** bar chart of paid by condition. **Explore:** trend a single condition (e.g., diabetes) over time.

### 2.6 Late Arrivals Impact
```sql
SELECT business_month, arrival_lag_days, late_claim_count
FROM GOLD.LATE_ARRIVALS
ORDER BY business_month, arrival_lag_days;
```
**Chart:** stacked column by lag bucket. **Explore:** restated paid before/after late arrivals; tie to lookback window in [`incremental_strategy.md`](incremental_strategy.md).

### 2.7 Data Quality / Quarantine Dashboard
```sql
SELECT model_name, reject_reason, COUNT(*) AS rows_quarantined
FROM CONTROL.QUARANTINE
WHERE NOT is_resolved
GROUP BY 1, 2 ORDER BY rows_quarantined DESC;

SELECT dq_check_name, dq_status, SUM(dq_failed_count) AS failed
FROM AUDIT.DQ_RESULTS
GROUP BY 1, 2;
```
**Chart:** bar chart of quarantine reasons + DQ pass/fail. **Explore:** quarantine growth over time (alert if rising).

### 2.8 Claim Adjustment / Reversal Analysis
```sql
SELECT
  DATE_TRUNC('month', business_event_ts) AS month,
  SUM(IFF(is_void,1,0))      AS voids,
  SUM(IFF(is_reversal,1,0))  AS reversals,
  COUNT(adjustment_of_claim_id) AS adjustments
FROM SILVER_CANONICAL.CLAIM_HEADER
GROUP BY 1 ORDER BY 1;
```
**Chart:** column chart of voids/reversals/adjustments per month. **Explore:** net paid impact of adjustment chains.

### 2.9 Eligibility Member Month Analysis
```sql
SELECT month, COUNT(DISTINCT member_id) AS members, COUNT(*) AS member_months
FROM GOLD.MEMBER_MONTHS
GROUP BY 1 ORDER BY 1;
```
**Chart:** line chart of member_months. **Explore:** confirm non-overlap; use as PMPM denominator sanity check.

### 2.10 Denial Analysis
```sql
SELECT month, payer_id, submitted, denied, denial_rate
FROM GOLD.DENIAL_SUMMARY
ORDER BY month, denial_rate DESC;
```
**Chart:** line of `denial_rate` per payer. **Explore:** correlate denial spikes with quarantine or late arrivals.

---

## 3. Tips

- Pin a top "context" cell that sets role/warehouse/db/schema so the whole Workbook is reproducible.
- Keep heavy aggregations in `GOLD`; Workbook cells should be thin selects so they stay fast and cheap.
- Use the same metric names as the semantic layer so Workbook charts and Cortex Analyst agree.
