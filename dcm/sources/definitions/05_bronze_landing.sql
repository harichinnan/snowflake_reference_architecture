/* =============================================================================
   05_bronze_landing.sql
   DCM declarative definitions for the RAW_LANDING landing tables (BR_RAW_*).
   -----------------------------------------------------------------------------
   Replaces the landing-table CREATE TABLEs (group B) that used to live in
   snowflake/setup/006_create_audit_tables.sql (now in 016_create_raw_landing.sql).
   These are the COPY INTO targets: append-only, source-faithful landing tables
   for each feed, in the RAW_LANDING schema (physical ingestion landing, NOT
   dbt-owned). The dbt-owned BRONZE.BR_RAW_* outputs are NOT DCM-defined.

   DCM-declarative DEFINE TABLE statements (CREATE-OR-ALTER form). No CREATE /
   IF NOT EXISTS / OR REPLACE; every object is fully qualified with the
   {{ database }} Jinja variable (CLAIMS_DEV / CLAIMS_PROD). No DML.
   ============================================================================= */

DEFINE TABLE {{ database }}.RAW_LANDING.BR_RAW_CLAIM_EVENT (
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
)
COMMENT = 'Bronze landing: raw CLAIM events (append-only, source-faithful, SYNTHETIC). COPY INTO target.';

DEFINE TABLE {{ database }}.RAW_LANDING.BR_RAW_ELIGIBILITY_EVENT (
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
)
COMMENT = 'Bronze landing: raw ELIGIBILITY events (append-only, SYNTHETIC). COPY INTO target.';

DEFINE TABLE {{ database }}.RAW_LANDING.BR_RAW_PROVIDER_EVENT (
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
)
COMMENT = 'Bronze landing: raw PROVIDER events (append-only, SYNTHETIC). COPY INTO target.';

DEFINE TABLE {{ database }}.RAW_LANDING.BR_RAW_PHARMACY_EVENT (
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
)
COMMENT = 'Bronze landing: raw PHARMACY events (append-only, SYNTHETIC). COPY INTO target.';

DEFINE TABLE {{ database }}.RAW_LANDING.BR_RAW_ADJUDICATION_EVENT (
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
)
COMMENT = 'Bronze landing: raw ADJUDICATION events (append-only, SYNTHETIC). COPY INTO target.';
