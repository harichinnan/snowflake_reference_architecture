-- =============================================================================
-- 09_bronze_x12.sql  ::  DCM declarative definitions for the X12 landing tables
-- Declarative form of the table DDL now in snowflake/setup/016_create_raw_landing.sql
-- (the internal stage + file format stay imperative in 015 -- DCM does not DEFINE
-- them). These are the RAW_LANDING physical landing tables (not dbt-owned); the
-- dbt-owned BRONZE.BR_RAW_X12_* outputs are NOT DCM-defined.
-- =============================================================================

-- Raw X12 837P EDI ingested AS-IS (one row per file).
DEFINE TABLE {{ database }}.RAW_LANDING.BR_RAW_X12_837 (
  BRONZE_EVENT_ID        STRING,
  SOURCE_SYSTEM          STRING,
  SOURCE_FILE_NAME       STRING,
  SOURCE_FILE_ROW_NUMBER NUMBER,
  SOURCE_EXTRACT_TS      TIMESTAMP_NTZ,
  INGEST_TS              TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  EVENT_TYPE             STRING,
  BUSINESS_EVENT_TS      TIMESTAMP_NTZ,
  NATURAL_KEY            STRING,
  X12_RAW                STRING,
  PAYLOAD                VARIANT,
  PAYLOAD_HASH           STRING,
  RECORD_STATUS          STRING,
  BATCH_ID               STRING,
  LOAD_ID                STRING,
  PIPELINE_RUN_ID        STRING,
  IS_REPROCESSED         BOOLEAN DEFAULT FALSE,
  QUARANTINE_REASON      STRING,
  CREATED_AT             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  UPDATED_AT             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Raw X12 837P EDI ingested as-is (one row per file). SYNTHETIC data.';

-- X12 837P parsed to JSON via moov-io/x12 (VARIANT payload).
DEFINE TABLE {{ database }}.RAW_LANDING.BR_RAW_X12_CLAIM_JSON (
  BRONZE_EVENT_ID        STRING,
  SOURCE_SYSTEM          STRING,
  SOURCE_FILE_NAME       STRING,
  SOURCE_FILE_ROW_NUMBER NUMBER,
  SOURCE_EXTRACT_TS      TIMESTAMP_NTZ,
  INGEST_TS              TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  EVENT_TYPE             STRING,
  BUSINESS_EVENT_TS      TIMESTAMP_NTZ,
  NATURAL_KEY            STRING,
  PAYLOAD                VARIANT,
  PAYLOAD_HASH           STRING,
  RECORD_STATUS          STRING,
  BATCH_ID               STRING,
  LOAD_ID                STRING,
  PIPELINE_RUN_ID        STRING,
  IS_REPROCESSED         BOOLEAN DEFAULT FALSE,
  QUARANTINE_REASON      STRING,
  SOURCE_X12_EVENT_ID    STRING,
  CREATED_AT             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  UPDATED_AT             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'X12 837P parsed to JSON via moov-io/x12 (VARIANT payload). SYNTHETIC.';
