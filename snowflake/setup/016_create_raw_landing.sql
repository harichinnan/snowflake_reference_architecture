/* =============================================================================
   016_create_raw_landing.sql
   snowflake-claims-platform :: PHYSICAL INGESTION LANDING schema (RAW_LANDING)
   -----------------------------------------------------------------------------
   Introduces RAW_LANDING -- the physical ingestion landing for all BR_RAW_*
   tables. This is the clean separation between:

     A) RAW_LANDING.BR_RAW_*  -- physical landing; the COPY INTO / loader targets.
                                  Owned by ingestion infrastructure (this script),
                                  NOT by dbt.
     B) BRONZE.BR_RAW_*        -- EXCLUSIVELY dbt model outputs. The dbt bronze
                                  models read source('bronze_landing', ...) ->
                                  RAW_LANDING and materialize into BRONZE. dbt
                                  owns BRONZE.BR_RAW_*; setup no longer creates them.

   The 7 landing tables created here (moved verbatim from 006 + 015):
        BR_RAW_CLAIM_EVENT, BR_RAW_ELIGIBILITY_EVENT, BR_RAW_PROVIDER_EVENT,
        BR_RAW_PHARMACY_EVENT, BR_RAW_ADJUDICATION_EVENT,
        BR_RAW_X12_837, BR_RAW_X12_CLAIM_JSON.

   Synthetic data only -- payloads contain NO real PHI. The BR_RAW_* payload
   VARIANT columns would, in a real system, hold sensitive data and MUST be
   masked + access-restricted (handled by CLAIMS_SECURITY_ADMIN).

   RUN AS: CLAIMS_SYSADMIN. Parameterised on $claims_db. IDEMPOTENT.
   ============================================================================= */

SET claims_db = 'CLAIMS_DEV';   -- override: -D claims_db=CLAIMS_PROD

USE ROLE CLAIMS_SYSADMIN;
USE DATABASE IDENTIFIER($claims_db);

/* =============================================================================
   1. RAW_LANDING schema -- physical ingestion landing (dbt does NOT own these).
   ============================================================================= */
CREATE SCHEMA IF NOT EXISTS RAW_LANDING
  COMMENT = 'Physical ingestion landing for BR_RAW_* tables (COPY/loader targets). dbt does NOT own these; BRONZE.BR_RAW_* are dbt outputs.';

USE SCHEMA RAW_LANDING;

/* =============================================================================
   2. LANDING TABLES (BR_RAW_*) -- COPY INTO / loader targets.
   -----------------------------------------------------------------------------
   Moved verbatim (identical columns/types/defaults/comments) from
   snowflake/setup/006_create_audit_tables.sql (the 5 event feeds) and
   snowflake/setup/015_create_x12_bronze.sql (the 2 X12 tables); only the schema
   changed BRONZE -> RAW_LANDING. Append-only, source-faithful.
   ============================================================================= */

/* --- BR_RAW_CLAIM_EVENT --- */
CREATE TABLE IF NOT EXISTS BR_RAW_CLAIM_EVENT (
  bronze_event_id        STRING        COMMENT 'Deterministic row id (file + row number hash).',
  source_system          STRING        COMMENT 'Originating source system.',
  source_file_name       STRING        COMMENT 'Stage file name (METADATA$FILENAME).',
  source_file_row_number NUMBER        COMMENT 'Row number within the file.',
  source_extract_ts      TIMESTAMP_NTZ COMMENT 'Producer-asserted extract timestamp.',
  ingest_ts              TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP() COMMENT 'When loaded into bronze.',
  event_type             STRING        COMMENT 'Event type discriminator.',
  business_event_ts      TIMESTAMP_NTZ COMMENT 'Business event time (watermark column).',
  natural_key            STRING        COMMENT 'Business natural key (e.g. claim_id).',
  payload                VARIANT       COMMENT 'Full source-faithful event JSON (SYNTHETIC).',
  payload_hash           STRING        COMMENT 'Hash of payload for dedupe/change detection.',
  record_status          STRING        COMMENT 'LANDED | QUARANTINED | SUPERSEDED.',
  batch_id               STRING        COMMENT 'FK -> CONTROL.LOAD_BATCH.',
  load_id                STRING        COMMENT 'Logical load id.',
  pipeline_run_id        STRING        COMMENT 'FK -> CONTROL.PIPELINE_RUN.',
  is_reprocessed         BOOLEAN       DEFAULT FALSE COMMENT 'TRUE if landed via reprocessing.',
  quarantine_reason      STRING        COMMENT 'Set when record_status=QUARANTINED.',
  created_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  updated_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'Bronze landing: raw CLAIM events (append-only, source-faithful, SYNTHETIC). COPY INTO target.';

/* --- BR_RAW_ELIGIBILITY_EVENT --- */
CREATE TABLE IF NOT EXISTS BR_RAW_ELIGIBILITY_EVENT (
  bronze_event_id        STRING,
  source_system          STRING,
  source_file_name       STRING,
  source_file_row_number NUMBER,
  source_extract_ts      TIMESTAMP_NTZ,
  ingest_ts              TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  event_type             STRING,
  business_event_ts      TIMESTAMP_NTZ,
  natural_key            STRING,
  payload                VARIANT,
  payload_hash           STRING,
  record_status          STRING,
  batch_id               STRING,
  load_id                STRING,
  pipeline_run_id        STRING,
  is_reprocessed         BOOLEAN DEFAULT FALSE,
  quarantine_reason      STRING,
  created_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  updated_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'Bronze landing: raw ELIGIBILITY events (append-only, SYNTHETIC). COPY INTO target.';

/* --- BR_RAW_PROVIDER_EVENT --- */
CREATE TABLE IF NOT EXISTS BR_RAW_PROVIDER_EVENT (
  bronze_event_id        STRING,
  source_system          STRING,
  source_file_name       STRING,
  source_file_row_number NUMBER,
  source_extract_ts      TIMESTAMP_NTZ,
  ingest_ts              TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  event_type             STRING,
  business_event_ts      TIMESTAMP_NTZ,
  natural_key            STRING,
  payload                VARIANT,
  payload_hash           STRING,
  record_status          STRING,
  batch_id               STRING,
  load_id                STRING,
  pipeline_run_id        STRING,
  is_reprocessed         BOOLEAN DEFAULT FALSE,
  quarantine_reason      STRING,
  created_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  updated_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'Bronze landing: raw PROVIDER events (append-only, SYNTHETIC). COPY INTO target.';

/* --- BR_RAW_PHARMACY_EVENT --- */
CREATE TABLE IF NOT EXISTS BR_RAW_PHARMACY_EVENT (
  bronze_event_id        STRING,
  source_system          STRING,
  source_file_name       STRING,
  source_file_row_number NUMBER,
  source_extract_ts      TIMESTAMP_NTZ,
  ingest_ts              TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  event_type             STRING,
  business_event_ts      TIMESTAMP_NTZ,
  natural_key            STRING,
  payload                VARIANT,
  payload_hash           STRING,
  record_status          STRING,
  batch_id               STRING,
  load_id                STRING,
  pipeline_run_id        STRING,
  is_reprocessed         BOOLEAN DEFAULT FALSE,
  quarantine_reason      STRING,
  created_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  updated_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'Bronze landing: raw PHARMACY events (append-only, SYNTHETIC). COPY INTO target.';

/* --- BR_RAW_ADJUDICATION_EVENT --- */
CREATE TABLE IF NOT EXISTS BR_RAW_ADJUDICATION_EVENT (
  bronze_event_id        STRING,
  source_system          STRING,
  source_file_name       STRING,
  source_file_row_number NUMBER,
  source_extract_ts      TIMESTAMP_NTZ,
  ingest_ts              TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  event_type             STRING,
  business_event_ts      TIMESTAMP_NTZ,
  natural_key            STRING,
  payload                VARIANT,
  payload_hash           STRING,
  record_status          STRING,
  batch_id               STRING,
  load_id                STRING,
  pipeline_run_id        STRING,
  is_reprocessed         BOOLEAN DEFAULT FALSE,
  quarantine_reason      STRING,
  created_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  updated_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'Bronze landing: raw ADJUDICATION events (append-only, SYNTHETIC). COPY INTO target.';

/* --- BR_RAW_X12_837 -- raw X12 837P EDI ingested as-is (one row per file). --- */
CREATE TABLE IF NOT EXISTS BR_RAW_X12_837 (
  bronze_event_id        STRING        COMMENT 'Deterministic row id (file hash).',
  source_system          STRING        COMMENT 'e.g. SYNTHEA_X12_837P.',
  source_file_name       STRING        COMMENT 'Originating .x12 file name.',
  source_file_row_number NUMBER        COMMENT 'Always 1 (one row per file).',
  source_extract_ts      TIMESTAMP_NTZ COMMENT 'Producer extract timestamp.',
  ingest_ts              TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP() COMMENT 'Load time.',
  event_type             STRING        COMMENT 'X12_837P.',
  business_event_ts      TIMESTAMP_NTZ COMMENT 'Business event time (watermark).',
  natural_key            STRING        COMMENT 'Interchange control number (ISA13).',
  x12_raw                STRING        COMMENT 'The full raw X12 EDI text, stored AS-IS.',
  payload                VARIANT       COMMENT 'Reserved (parsed JSON lives in BR_RAW_X12_CLAIM_JSON).',
  payload_hash           STRING        COMMENT 'sha2 of x12_raw (dedupe/idempotency).',
  record_status          STRING        COMMENT 'LANDED | PROCESSED | QUARANTINE.',
  batch_id               STRING,
  load_id                STRING,
  pipeline_run_id        STRING,
  is_reprocessed         BOOLEAN       DEFAULT FALSE,
  quarantine_reason      STRING,
  created_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  updated_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Raw X12 837P EDI ingested as-is (one row per file). SYNTHETIC data.';

/* --- BR_RAW_X12_CLAIM_JSON -- X12 837P parsed to JSON (moov-io/x12). --- */
CREATE TABLE IF NOT EXISTS BR_RAW_X12_CLAIM_JSON (
  bronze_event_id        STRING        COMMENT 'Deterministic row id.',
  source_system          STRING        COMMENT 'X12_837P_MOOV_JSON.',
  source_file_name       STRING        COMMENT 'Originating .x12 file name.',
  source_file_row_number NUMBER        COMMENT 'Always 1 (one row per file).',
  source_extract_ts      TIMESTAMP_NTZ,
  ingest_ts              TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  event_type             STRING        COMMENT 'X12_837P_JSON.',
  business_event_ts      TIMESTAMP_NTZ,
  natural_key            STRING        COMMENT 'Interchange control number (ISA13).',
  payload                VARIANT       COMMENT 'moov-io/x12 flat labeled JSON (segments[]).',
  payload_hash           STRING,
  record_status          STRING        COMMENT 'LANDED | VALID | QUARANTINE.',
  batch_id               STRING,
  load_id                STRING,
  pipeline_run_id        STRING,
  is_reprocessed         BOOLEAN       DEFAULT FALSE,
  quarantine_reason      STRING,
  source_x12_event_id    STRING        COMMENT 'FK -> BR_RAW_X12_837.bronze_event_id.',
  created_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  updated_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'X12 837P parsed to JSON via moov-io/x12 (VARIANT payload). SYNTHETIC.';

/* =============================================================================
   3. GRANTS on RAW_LANDING.
   -----------------------------------------------------------------------------
   LOADER writes the landing (COPY INTO + loader/Airflow INSERT/UPDATE);
   TRANSFORMER reads it as the dbt bronze-model source. RAW_LANDING is NOT
   granted to CLAIMS_ANALYST or CLAIMS_MCP_READER.
   ============================================================================= */
GRANT USAGE ON SCHEMA RAW_LANDING TO ROLE CLAIMS_LOADER;
GRANT USAGE ON SCHEMA RAW_LANDING TO ROLE CLAIMS_TRANSFORMER;

GRANT SELECT, INSERT, UPDATE ON ALL TABLES    IN SCHEMA RAW_LANDING TO ROLE CLAIMS_LOADER;
GRANT SELECT, INSERT, UPDATE ON FUTURE TABLES IN SCHEMA RAW_LANDING TO ROLE CLAIMS_LOADER;
GRANT SELECT ON ALL TABLES    IN SCHEMA RAW_LANDING TO ROLE CLAIMS_TRANSFORMER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA RAW_LANDING TO ROLE CLAIMS_TRANSFORMER;

/* =============================================================================
   4. NONDESTRUCTIVE MIGRATION / BACKFILL
   -----------------------------------------------------------------------------
   Before this change, ingestion wrote BRONZE.BR_RAW_* directly. Those legacy
   landing rows must be copied into RAW_LANDING so the new pipeline (loaders ->
   RAW_LANDING; dbt sources -> RAW_LANDING; dbt outputs -> BRONZE) sees the full
   history. This block is NONDESTRUCTIVE: it only INSERTs into RAW_LANDING and
   never drops the legacy BRONZE rows.

   Run order:
     STEP 1) Run this script up to here (creates RAW_LANDING + the 7 tables).
     STEP 2) Run the INSERT ... SELECT backfills below (one per landing table).
             Column lists are explicit and identical between source/target.
     STEP 3) Repoint loaders/COPY/Airflow/streams to RAW_LANDING (already done in
             the companion files) and run a dbt FULL-REFRESH of the bronze models
             so BRONZE.BR_RAW_* are recreated as dbt outputs reading RAW_LANDING.
     STEP 4) After STEP 3 validates, the legacy in-place BRONZE.BR_RAW_* DATA is
             SUPERSEDED by dbt's outputs. The legacy rows that pre-date the dbt
             takeover can then be dropped LAST (manual, deliberate -- not here),
             e.g. by letting dbt's full-refresh replace the BRONZE.BR_RAW_*
             relations entirely.

   NOTE: these backfills are guarded by checking the legacy table exists; if a
   fresh environment never had BRONZE.BR_RAW_* populated, they are simple no-ops
   over empty/absent source data. Comment out any feed you did not previously run.
   ============================================================================= */

-- STEP 2.1) BR_RAW_CLAIM_EVENT
INSERT INTO RAW_LANDING.BR_RAW_CLAIM_EVENT
  (bronze_event_id, source_system, source_file_name, source_file_row_number,
   source_extract_ts, ingest_ts, event_type, business_event_ts, natural_key,
   payload, payload_hash, record_status, batch_id, load_id, pipeline_run_id,
   is_reprocessed, quarantine_reason, created_at, updated_at)
SELECT
   bronze_event_id, source_system, source_file_name, source_file_row_number,
   source_extract_ts, ingest_ts, event_type, business_event_ts, natural_key,
   payload, payload_hash, record_status, batch_id, load_id, pipeline_run_id,
   is_reprocessed, quarantine_reason, created_at, updated_at
FROM BRONZE.BR_RAW_CLAIM_EVENT;

-- STEP 2.2) BR_RAW_ELIGIBILITY_EVENT
INSERT INTO RAW_LANDING.BR_RAW_ELIGIBILITY_EVENT
  (bronze_event_id, source_system, source_file_name, source_file_row_number,
   source_extract_ts, ingest_ts, event_type, business_event_ts, natural_key,
   payload, payload_hash, record_status, batch_id, load_id, pipeline_run_id,
   is_reprocessed, quarantine_reason, created_at, updated_at)
SELECT
   bronze_event_id, source_system, source_file_name, source_file_row_number,
   source_extract_ts, ingest_ts, event_type, business_event_ts, natural_key,
   payload, payload_hash, record_status, batch_id, load_id, pipeline_run_id,
   is_reprocessed, quarantine_reason, created_at, updated_at
FROM BRONZE.BR_RAW_ELIGIBILITY_EVENT;

-- STEP 2.3) BR_RAW_PROVIDER_EVENT
INSERT INTO RAW_LANDING.BR_RAW_PROVIDER_EVENT
  (bronze_event_id, source_system, source_file_name, source_file_row_number,
   source_extract_ts, ingest_ts, event_type, business_event_ts, natural_key,
   payload, payload_hash, record_status, batch_id, load_id, pipeline_run_id,
   is_reprocessed, quarantine_reason, created_at, updated_at)
SELECT
   bronze_event_id, source_system, source_file_name, source_file_row_number,
   source_extract_ts, ingest_ts, event_type, business_event_ts, natural_key,
   payload, payload_hash, record_status, batch_id, load_id, pipeline_run_id,
   is_reprocessed, quarantine_reason, created_at, updated_at
FROM BRONZE.BR_RAW_PROVIDER_EVENT;

-- STEP 2.4) BR_RAW_PHARMACY_EVENT
INSERT INTO RAW_LANDING.BR_RAW_PHARMACY_EVENT
  (bronze_event_id, source_system, source_file_name, source_file_row_number,
   source_extract_ts, ingest_ts, event_type, business_event_ts, natural_key,
   payload, payload_hash, record_status, batch_id, load_id, pipeline_run_id,
   is_reprocessed, quarantine_reason, created_at, updated_at)
SELECT
   bronze_event_id, source_system, source_file_name, source_file_row_number,
   source_extract_ts, ingest_ts, event_type, business_event_ts, natural_key,
   payload, payload_hash, record_status, batch_id, load_id, pipeline_run_id,
   is_reprocessed, quarantine_reason, created_at, updated_at
FROM BRONZE.BR_RAW_PHARMACY_EVENT;

-- STEP 2.5) BR_RAW_ADJUDICATION_EVENT
INSERT INTO RAW_LANDING.BR_RAW_ADJUDICATION_EVENT
  (bronze_event_id, source_system, source_file_name, source_file_row_number,
   source_extract_ts, ingest_ts, event_type, business_event_ts, natural_key,
   payload, payload_hash, record_status, batch_id, load_id, pipeline_run_id,
   is_reprocessed, quarantine_reason, created_at, updated_at)
SELECT
   bronze_event_id, source_system, source_file_name, source_file_row_number,
   source_extract_ts, ingest_ts, event_type, business_event_ts, natural_key,
   payload, payload_hash, record_status, batch_id, load_id, pipeline_run_id,
   is_reprocessed, quarantine_reason, created_at, updated_at
FROM BRONZE.BR_RAW_ADJUDICATION_EVENT;

-- STEP 2.6) BR_RAW_X12_837 (note the extra x12_raw column)
INSERT INTO RAW_LANDING.BR_RAW_X12_837
  (bronze_event_id, source_system, source_file_name, source_file_row_number,
   source_extract_ts, ingest_ts, event_type, business_event_ts, natural_key,
   x12_raw, payload, payload_hash, record_status, batch_id, load_id,
   pipeline_run_id, is_reprocessed, quarantine_reason, created_at, updated_at)
SELECT
   bronze_event_id, source_system, source_file_name, source_file_row_number,
   source_extract_ts, ingest_ts, event_type, business_event_ts, natural_key,
   x12_raw, payload, payload_hash, record_status, batch_id, load_id,
   pipeline_run_id, is_reprocessed, quarantine_reason, created_at, updated_at
FROM BRONZE.BR_RAW_X12_837;

-- STEP 2.7) BR_RAW_X12_CLAIM_JSON (note the extra source_x12_event_id column)
INSERT INTO RAW_LANDING.BR_RAW_X12_CLAIM_JSON
  (bronze_event_id, source_system, source_file_name, source_file_row_number,
   source_extract_ts, ingest_ts, event_type, business_event_ts, natural_key,
   payload, payload_hash, record_status, batch_id, load_id, pipeline_run_id,
   is_reprocessed, quarantine_reason, source_x12_event_id, created_at, updated_at)
SELECT
   bronze_event_id, source_system, source_file_name, source_file_row_number,
   source_extract_ts, ingest_ts, event_type, business_event_ts, natural_key,
   payload, payload_hash, record_status, batch_id, load_id, pipeline_run_id,
   is_reprocessed, quarantine_reason, source_x12_event_id, created_at, updated_at
FROM BRONZE.BR_RAW_X12_CLAIM_JSON;

/* DONE. RAW_LANDING created + backfilled. After a dbt full-refresh of the bronze
   models, BRONZE.BR_RAW_* are dbt outputs and the legacy BRONZE landing data is
   superseded (drop legacy rows/relations LAST, deliberately). */
