# Semantic Layer — `snowflake-claims-platform`

> **SYNTHETIC DATA DISCLAIMER.** Every table, key, code, NPI, member id, and
> dollar amount referenced here is **machine-generated** by
> `data_generator/generate_synthetic_claims.py`. This is **not** real
> CMS / Medicare / Medicaid / TAF / RIF data and contains **no PHI/PII**. Metric
> *definitions* are production-grade and certified; the *values* are fabricated.
> Never present a result as a real clinical or financial fact.

This folder is the **governed semantic / metric layer** on top of the dbt
`GOLD` and `SILVER_DIMENSIONAL` star. It turns the certified marts into a single
natural-language-queryable surface for **Cortex Analyst**, **Cortex Search**,
and the **Snowflake-managed MCP** server. A business metric — *PMPM*, *denial
rate*, *member months* — is defined **once** here and means the same thing
everywhere.

---

## 1. What lives here

| File | What it is | Consumed by |
|---|---|---|
| `README.md` | This document. | Humans. |
| `cortex_analyst_claims_semantic_model.yaml` | The **Cortex Analyst** semantic model (logical tables, dimensions, time dimensions, measures, named metrics, relationships, verified queries, custom instructions, disambiguation). | Cortex Analyst → MCP → LLM clients. |
| `semantic_view_claims.sql` | Native Snowflake **`SEMANTIC VIEW`** (`SEMANTIC.CLAIMS_SEMANTIC_VIEW`) over the gold/dimensional star, with a governed-`VIEW` fallback. | `SEMANTIC_VIEW(...)`, Cortex Analyst, workbooks. |
| `cortex_search_objects.sql` | **Cortex Search services** over provider lookup, metric/dictionary docs, runbook + AUDIT DQ/quarantine summaries. | Cortex Search → Agent / MCP retrieval. |
| `verified_queries.yml` | Human-validated NL→SQL exemplars (also inlined in the YAML). | Cortex Analyst. |
| `metric_registry_seed.sql` | Seeds `SEMANTIC.METRIC_REGISTRY` **and** `CONTROL.SEMANTIC_METRIC_REGISTRY` with **certified** metrics. | Certification governance + Cortex Search docs. |
| `data_dictionary_seed.sql` | Seeds `SEMANTIC.DATA_DICTIONARY` with table/column meanings. | Cortex Search ("what does paid amount mean?"). |
| `claims_runbook_seed.sql` | Seeds `SEMANTIC.CLAIMS_RUNBOOK` with operational Q&A (late arrivals, adjustments/reversals, quarantine, PMPM math). | Cortex Search / agent troubleshooting. |

---

## 2. Two semantic surfaces: native `SEMANTIC VIEW` vs Cortex Analyst YAML

The platform ships **both** representations of the same model. They serve
different runtimes and are kept in sync against the same certified gold models
and the same metric registry.

### 2a. Snowflake `SEMANTIC VIEW` (SQL-native)

A first-class Snowflake object created with `CREATE SEMANTIC VIEW`. It declares
**logical tables** (mapped to physical gold/dimensional objects),
**relationships**, **facts**, **dimensions**, and **metrics** in DDL, and is
queried with the `SEMANTIC_VIEW(...)` table function:

```sql
SELECT * FROM SEMANTIC_VIEW(
  SEMANTIC.CLAIMS_SEMANTIC_VIEW
    DIMENSIONS claim_line.plan_type, claim_line.claim_month
    METRICS    claim_line.total_paid
);
```

Strengths: governed by Snowflake RBAC/masking, queryable directly from SQL/BI,
and the metric expression lives in the database (one definition, no drift). See
`semantic_view_claims.sql`. Where a clause is not GA in a given account, that
file comments it and provides a **governed `VIEW` fallback** so downstream
references never break.

### 2b. Cortex Analyst semantic model (YAML)

Cortex Analyst consumes a **YAML semantic model** optimized for text-to-SQL:
logical tables → base tables, dimensions, time dimensions, measures, named
metrics, relationships, **synonyms**, **verified queries**, **custom
instructions**, and **disambiguation rules**. These steer the LLM toward the
**certified** definitions instead of inventing aggregations. A Cortex Analyst
model may also *point at* the `SEMANTIC VIEW`; we keep the YAML as the
conversational source-of-truth and the `SEMANTIC VIEW` as the SQL surface, with
identical metric math.

---

## 3. How it maps to the gold models

The semantic layer **never** reads `RAW`/`BRONZE`. It is built only on certified
`GOLD` products plus one `SILVER_DIMENSIONAL` denominator. Column names below are
the **actual** model columns.

| Logical table | Backing object | Grain | Key columns / measures |
|---|---|---|---|
| `claim_line` (primary fact) | `GOLD.gold_claims_semantic_base` | claim **service line** | `fact_claim_line_sk`; `paid_amount`, `allowed_amount`, `charge_amount`, `patient_responsibility`, `units`; flags `denial_flag`/`adjustment_flag`/`reversal_flag`; `claim_month`/`service_date`. |
| `member_months` | `GOLD.gold_member_months` | (payer, plan, month) | `payer_sk`, `plan_sk`, `month_start`; `member_months`, `distinct_members`. |
| `payer_plan_summary` | `GOLD.gold_payer_plan_summary` | (payer, plan, month) | `total_paid`, `total_allowed`, `total_charge`, `claim_count`, `member_months`, `pmpm`, `denial_rate`. |
| `provider_utilization` | `GOLD.gold_provider_utilization` | (provider, month) | `provider_npi`, `specialty`, `provider_state`, `month_start`; `claims`, `total_paid`, `distinct_members`, `paid_per_member`. |
| `condition_cost_summary` | `GOLD.gold_condition_cost_summary` | (condition_group, month) | `condition_group`, `claim_month`; `distinct_members_with_condition`, `total_paid`, `paid_per_member`, `top_procedures`. |
| `claim_denial_summary` | `GOLD.gold_claim_denial_summary` | (payer, plan, status, reason, month) | `denial_reason`, `total_claims`, `denied_claims`, `denial_rate`. |
| `late_arrival_impact` | `GOLD.gold_late_arrival_impact` | impacted service month | `impacted_period`; `original_paid`, `late_paid`, `restated_paid`, `paid_delta`. |
| `eligibility_month` | `SILVER_DIMENSIONAL.fact_eligibility_month` | (member, payer, plan, coverage month) | `member_id`, `payer_sk`, `plan_sk`, `month_start`; `member_month_flag`. |

Joins from the fact to the summaries are on the conformed **surrogate** keys
`payer_sk`, `plan_sk`, the month (`claim_month`/`month_start`), and
`condition_group`. (The wide base carries `payer_sk`/`plan_sk`, not raw
`payer_id`/`plan_id`.)

---

## 4. Metric certification via the registry

Every measure surfaced to Cortex carries a **certification status**. Two
registries hold the **same** certified definitions:

- **`CONTROL.SEMANTIC_METRIC_REGISTRY`** — the governance copy (ownership,
  lineage, `certified_status`); created by `snowflake/setup/005`.
- **`SEMANTIC.METRIC_REGISTRY`** — the presentation copy **Cortex Search**
  indexes, so "how is PMPM computed?" is answered from governed docs, not
  hallucination; created by `snowflake/setup/012`.

`metric_registry_seed.sql` populates **both** with the certified set, each row
carrying `business_definition`, `calculation_sql`, `grain`, `owner`,
`certified_status = 'CERTIFIED'`, `source_model`, `allowed_dimensions` (a VARIANT
array — the only dimensions a metric may be sliced by), and `default_filters`.

| Metric | Definition (synthetic) | Source model |
|---|---|---|
| `total_paid_amount` | `SUM(paid_amount)` — adjudicated paid, current valid version only. | `gold_claims_semantic_base` / `gold_payer_plan_summary` |
| `allowed_amount` | `SUM(allowed_amount)` — contractually allowed. | `gold_claims_semantic_base` |
| `charge_amount` | `SUM(charge_amount)` — billed/submitted. | `gold_claims_semantic_base` |
| `pmpm` | `SUM(paid_amount) / NULLIF(SUM(member_months),0)`. | `gold_payer_plan_summary` |
| `member_months` | `SUM(member_month_flag)`. | `gold_member_months` |
| `distinct_members` | `COUNT(DISTINCT member_id)`. | `gold_claims_semantic_base` |
| `denial_rate` | `denied_claims / NULLIF(total_claims,0)` (recomputed, not averaged). | `gold_claim_denial_summary` |
| `adjustment_count` | `COUNT(DISTINCT CASE WHEN adjustment_flag THEN claim_id END)`. | `gold_claims_semantic_base` |
| `reversal_count` | `COUNT(DISTINCT CASE WHEN reversal_flag THEN claim_id END)`. | `gold_claims_semantic_base` |
| `claims_volume` | `COUNT(DISTINCT claim_id)`. | `gold_claims_semantic_base` |

**Governance contract:** Cortex Analyst's `custom_instructions` require it to
*prefer certified metrics and state the definition used*. "Cost" resolves to
`paid_amount` by default; "members" = distinct patients; "month" = `claim_month`.

---

## 5. Business questions answered

The verified queries (`verified_queries.yml`, mirrored in the YAML) cover:

1. Total paid amount by month.
2. PMPM by plan type.
3. Member months by payer.
4. Claims volume by status.
5. Denial rate by payer / plan.
6. Provider utilization by specialty.
7. Condition cost summary (unique members with a condition; cost per member).
8. Late-arriving claim impact (why a prior month's paid changed).
9. Adjustment / reversal counts.
10. Claim line ↔ header reconciliation status.

---

## 6. How Cortex Analyst + Cortex Search + MCP consume this

```
            ┌─────────────────────────────────────────────────────────┐
  NL ask →  │  Snowflake-managed MCP server  (WH_CLAIMS_MCP, RBAC)     │
            │   tools: cortex_analyst · cortex_search · run_sql(MCP_*) │
            └───────────────┬───────────────────────┬─────────────────┘
                            │                       │
                ┌───────────▼─────────┐   ┌─────────▼──────────────┐
                │  Cortex Analyst     │   │  Cortex Search          │
                │  (text-to-SQL)      │   │  (semantic retrieval)   │
                │  YAML / SEMANTIC    │   │  doc + provider + DQ     │
                │  VIEW + verified Qs │   │  services               │
                └───────────┬─────────┘   └─────────┬──────────────┘
                            │                       │
              certified SQL over GOLD        provider lookup,
              + verified queries             metric docs, runbook,
                                             DQ/quarantine summaries
```

- **Cortex Analyst** turns a question into governed SQL using the YAML/semantic
  view — logical tables, named metrics, synonyms, disambiguation, and verified
  queries as exemplars. It returns SQL + result, never free-text math.
- **Cortex Search** (`cortex_search_objects.sql`):
  - `CLAIMS_PROVIDER_SEARCH` — resolve fuzzy provider mentions → NPI.
  - `CLAIMS_METRIC_DOC_SEARCH` — definitional Q&A from `METRIC_REGISTRY` +
    `DATA_DICTIONARY`.
  - `CLAIMS_DATA_QUALITY_SEARCH` — operational/DQ Q&A from `CLAIMS_RUNBOOK` +
    AUDIT DQ / quarantine summaries.
- **MCP** (Snowflake-managed) exposes both as least-privilege tools to LLM
  clients (Claude Desktop, Cursor, VS Code; configs under `mcp/clients/`),
  running on `WH_CLAIMS_MCP` under `CLAIMS_MCP_READER`. Its direct-SQL tool is
  restricted to the narrow `SEMANTIC.MCP_*` views; everything analytic flows
  through Analyst.

---

## 7. Deploy order

```bash
# 1. Build the certified gold models first (Analyst/MCP read them).
dbt build

# 2. Create CONTROL + SEMANTIC tables and the baseline semantic view.
snowsql -f snowflake/setup/005_create_control_tables.sql      # CONTROL.SEMANTIC_METRIC_REGISTRY
snowsql -f snowflake/setup/012_create_semantic_views.sql      # SEMANTIC.* tables + CLAIMS_SEMANTIC_VIEW

# 3. Seed the governed docs / metric registry from this folder.
snowsql -f semantic/metric_registry_seed.sql
snowsql -f semantic/data_dictionary_seed.sql
snowsql -f semantic/claims_runbook_seed.sql

# 4. (Re)apply the curated semantic view + search services from this folder.
snowsql -f semantic/semantic_view_claims.sql
snowsql -f semantic/cortex_search_objects.sql

# 5. Upload the Analyst YAML to a stage and register it with Cortex Analyst.
#    PUT file://semantic/cortex_analyst_claims_semantic_model.yaml @SEMANTIC.SEMANTIC_STAGE;

# Add -D claims_db=CLAIMS_PROD on each snowsql call for the prod deploy.
```

Run as `CLAIMS_SYSADMIN` for object creation; read is granted to
`CLAIMS_ANALYST` / `CLAIMS_MCP_READER`. Everything is idempotent
(`CREATE OR REPLACE` / `MERGE`).

> **Schema note.** Seeds use the table shapes documented at the top of each seed
> file. If a deployed `SEMANTIC.*` table (from `setup/012`) differs, align the
> column list; each seed is a `MERGE`, so re-running after an `ALTER TABLE` is
> safe.
