-- =============================================================================
-- put_and_copy.sql  ::  Ingest SYNTHETIC claims NDJSON directly into Snowflake
-- -----------------------------------------------------------------------------
-- 100% Snowflake ingestion: PUT local NDJSON -> RAW internal stage -> COPY INTO
-- the BRONZE landing tables. NO external object storage (no S3/GCS/Blob).
--
-- Run from the REPO ROOT (file:// paths are relative to the process CWD), with a
-- role that can write BRONZE (ACCOUNTADMIN / CLAIMS_SYSADMIN / CLAIMS_LOADER):
--   snow sql -c my_example_connection --filename snowflake/load/put_and_copy.sql
-- or:  make stage-load
--
-- The NDJSON envelope (per line) is:
--   { source_system, source_file_name, source_extract_ts, file_generation_ts,
--     event_type, business_event_ts, natural_key, payload_hash, payload {...} }
-- COPY maps the envelope to provenance columns and keeps `payload` as VARIANT.
-- The dbt BRONZE models then derive record_status = VALID / QUARANTINE.
--
-- Data is SYNTHETIC — not real CMS/Medicare/Medicaid/PHI.
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE CLAIMS_DEV;
USE WAREHOUSE WH_CLAIMS_LOAD;
USE SCHEMA RAW;

-- One logical load id for this run (DCM batch/load control).
SET load_id = 'LOAD_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDDHH24MISS');

-- =============================================================================
-- CLAIM EVENTS  ->  BRONZE.BR_RAW_CLAIM_EVENT
-- =============================================================================
PUT 'file://data_generator/output/claim_events.ndjson' @STG_CLAIM_EVENT
  OVERWRITE = TRUE AUTO_COMPRESS = TRUE;

COPY INTO CLAIMS_DEV.BRONZE.BR_RAW_CLAIM_EVENT
  (bronze_event_id, source_system, source_file_name, source_file_row_number,
   source_extract_ts, event_type, business_event_ts, natural_key, payload,
   payload_hash, record_status, batch_id, load_id, is_reprocessed)
FROM (
  SELECT
    SHA2(METADATA$FILENAME || ':' || METADATA$FILE_ROW_NUMBER, 256),
    $1:source_system::string,
    METADATA$FILENAME,
    METADATA$FILE_ROW_NUMBER,
    TRY_TO_TIMESTAMP_NTZ($1:source_extract_ts::string),
    $1:event_type::string,
    TRY_TO_TIMESTAMP_NTZ($1:business_event_ts::string),
    $1:natural_key::string,
    $1:payload,
    $1:payload_hash::string,
    'LANDED',
    $load_id || '_CLAIM',
    $load_id,
    FALSE
  FROM @STG_CLAIM_EVENT
)
FILE_FORMAT = (FORMAT_NAME = CLAIMS_DEV.RAW.FF_JSON_NDJSON)
ON_ERROR = 'CONTINUE';

INSERT INTO CLAIMS_DEV.CONTROL.LOAD_BATCH
  (batch_id, source_system, source_file_name, file_arrival_ts, file_row_count, load_status, loaded_at)
SELECT $load_id || '_CLAIM', 'CLAIMS_CORE', 'claim_events.ndjson', CURRENT_TIMESTAMP(),
       (SELECT COUNT(*) FROM CLAIMS_DEV.BRONZE.BR_RAW_CLAIM_EVENT WHERE load_id = $load_id),
       'LOADED', CURRENT_TIMESTAMP();

-- =============================================================================
-- ELIGIBILITY EVENTS  ->  BRONZE.BR_RAW_ELIGIBILITY_EVENT
-- =============================================================================
PUT 'file://data_generator/output/eligibility_events.ndjson' @STG_ELIGIBILITY_EVENT
  OVERWRITE = TRUE AUTO_COMPRESS = TRUE;

COPY INTO CLAIMS_DEV.BRONZE.BR_RAW_ELIGIBILITY_EVENT
  (bronze_event_id, source_system, source_file_name, source_file_row_number,
   source_extract_ts, event_type, business_event_ts, natural_key, payload,
   payload_hash, record_status, batch_id, load_id, is_reprocessed)
FROM (
  SELECT
    SHA2(METADATA$FILENAME || ':' || METADATA$FILE_ROW_NUMBER, 256),
    $1:source_system::string, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER,
    TRY_TO_TIMESTAMP_NTZ($1:source_extract_ts::string), $1:event_type::string,
    TRY_TO_TIMESTAMP_NTZ($1:business_event_ts::string), $1:natural_key::string,
    $1:payload, $1:payload_hash::string, 'LANDED', $load_id || '_ELIG', $load_id, FALSE
  FROM @STG_ELIGIBILITY_EVENT
)
FILE_FORMAT = (FORMAT_NAME = CLAIMS_DEV.RAW.FF_JSON_NDJSON)
ON_ERROR = 'CONTINUE';

INSERT INTO CLAIMS_DEV.CONTROL.LOAD_BATCH
  (batch_id, source_system, source_file_name, file_arrival_ts, file_row_count, load_status, loaded_at)
SELECT $load_id || '_ELIG', 'ELIG_SYS', 'eligibility_events.ndjson', CURRENT_TIMESTAMP(),
       (SELECT COUNT(*) FROM CLAIMS_DEV.BRONZE.BR_RAW_ELIGIBILITY_EVENT WHERE load_id = $load_id),
       'LOADED', CURRENT_TIMESTAMP();

-- =============================================================================
-- PROVIDER EVENTS  ->  BRONZE.BR_RAW_PROVIDER_EVENT
-- =============================================================================
PUT 'file://data_generator/output/provider_events.ndjson' @STG_PROVIDER_EVENT
  OVERWRITE = TRUE AUTO_COMPRESS = TRUE;

COPY INTO CLAIMS_DEV.BRONZE.BR_RAW_PROVIDER_EVENT
  (bronze_event_id, source_system, source_file_name, source_file_row_number,
   source_extract_ts, event_type, business_event_ts, natural_key, payload,
   payload_hash, record_status, batch_id, load_id, is_reprocessed)
FROM (
  SELECT
    SHA2(METADATA$FILENAME || ':' || METADATA$FILE_ROW_NUMBER, 256),
    $1:source_system::string, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER,
    TRY_TO_TIMESTAMP_NTZ($1:source_extract_ts::string), $1:event_type::string,
    TRY_TO_TIMESTAMP_NTZ($1:business_event_ts::string), $1:natural_key::string,
    $1:payload, $1:payload_hash::string, 'LANDED', $load_id || '_PROV', $load_id, FALSE
  FROM @STG_PROVIDER_EVENT
)
FILE_FORMAT = (FORMAT_NAME = CLAIMS_DEV.RAW.FF_JSON_NDJSON)
ON_ERROR = 'CONTINUE';

INSERT INTO CLAIMS_DEV.CONTROL.LOAD_BATCH
  (batch_id, source_system, source_file_name, file_arrival_ts, file_row_count, load_status, loaded_at)
SELECT $load_id || '_PROV', 'PROVIDER_MD', 'provider_events.ndjson', CURRENT_TIMESTAMP(),
       (SELECT COUNT(*) FROM CLAIMS_DEV.BRONZE.BR_RAW_PROVIDER_EVENT WHERE load_id = $load_id),
       'LOADED', CURRENT_TIMESTAMP();

-- =============================================================================
-- PHARMACY EVENTS  ->  BRONZE.BR_RAW_PHARMACY_EVENT
-- =============================================================================
PUT 'file://data_generator/output/pharmacy_events.ndjson' @STG_PHARMACY_EVENT
  OVERWRITE = TRUE AUTO_COMPRESS = TRUE;

COPY INTO CLAIMS_DEV.BRONZE.BR_RAW_PHARMACY_EVENT
  (bronze_event_id, source_system, source_file_name, source_file_row_number,
   source_extract_ts, event_type, business_event_ts, natural_key, payload,
   payload_hash, record_status, batch_id, load_id, is_reprocessed)
FROM (
  SELECT
    SHA2(METADATA$FILENAME || ':' || METADATA$FILE_ROW_NUMBER, 256),
    $1:source_system::string, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER,
    TRY_TO_TIMESTAMP_NTZ($1:source_extract_ts::string), $1:event_type::string,
    TRY_TO_TIMESTAMP_NTZ($1:business_event_ts::string), $1:natural_key::string,
    $1:payload, $1:payload_hash::string, 'LANDED', $load_id || '_PHRM', $load_id, FALSE
  FROM @STG_PHARMACY_EVENT
)
FILE_FORMAT = (FORMAT_NAME = CLAIMS_DEV.RAW.FF_JSON_NDJSON)
ON_ERROR = 'CONTINUE';

INSERT INTO CLAIMS_DEV.CONTROL.LOAD_BATCH
  (batch_id, source_system, source_file_name, file_arrival_ts, file_row_count, load_status, loaded_at)
SELECT $load_id || '_PHRM', 'RX_HUB', 'pharmacy_events.ndjson', CURRENT_TIMESTAMP(),
       (SELECT COUNT(*) FROM CLAIMS_DEV.BRONZE.BR_RAW_PHARMACY_EVENT WHERE load_id = $load_id),
       'LOADED', CURRENT_TIMESTAMP();

-- =============================================================================
-- ADJUDICATION EVENTS  ->  BRONZE.BR_RAW_ADJUDICATION_EVENT
-- =============================================================================
PUT 'file://data_generator/output/adjudication_events.ndjson' @STG_ADJUDICATION_EVENT
  OVERWRITE = TRUE AUTO_COMPRESS = TRUE;

COPY INTO CLAIMS_DEV.BRONZE.BR_RAW_ADJUDICATION_EVENT
  (bronze_event_id, source_system, source_file_name, source_file_row_number,
   source_extract_ts, event_type, business_event_ts, natural_key, payload,
   payload_hash, record_status, batch_id, load_id, is_reprocessed)
FROM (
  SELECT
    SHA2(METADATA$FILENAME || ':' || METADATA$FILE_ROW_NUMBER, 256),
    $1:source_system::string, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER,
    TRY_TO_TIMESTAMP_NTZ($1:source_extract_ts::string), $1:event_type::string,
    TRY_TO_TIMESTAMP_NTZ($1:business_event_ts::string), $1:natural_key::string,
    $1:payload, $1:payload_hash::string, 'LANDED', $load_id || '_ADJD', $load_id, FALSE
  FROM @STG_ADJUDICATION_EVENT
)
FILE_FORMAT = (FORMAT_NAME = CLAIMS_DEV.RAW.FF_JSON_NDJSON)
ON_ERROR = 'CONTINUE';

INSERT INTO CLAIMS_DEV.CONTROL.LOAD_BATCH
  (batch_id, source_system, source_file_name, file_arrival_ts, file_row_count, load_status, loaded_at)
SELECT $load_id || '_ADJD', 'ADJUD_ENGINE', 'adjudication_events.ndjson', CURRENT_TIMESTAMP(),
       (SELECT COUNT(*) FROM CLAIMS_DEV.BRONZE.BR_RAW_ADJUDICATION_EVENT WHERE load_id = $load_id),
       'LOADED', CURRENT_TIMESTAMP();

-- =============================================================================
-- Summary
-- =============================================================================
SELECT batch_id, source_system, source_file_name, file_row_count, load_status
FROM CLAIMS_DEV.CONTROL.LOAD_BATCH
WHERE batch_id LIKE $load_id || '%'
ORDER BY batch_id;
