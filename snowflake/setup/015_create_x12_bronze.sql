-- =============================================================================
-- 015_create_x12_bronze.sql
-- -----------------------------------------------------------------------------
-- Internal stage + file format for the SYNTHEA -> X12 837P -> JSON pipeline.
--
-- NOTE: the BR_RAW_X12_837 and BR_RAW_X12_CLAIM_JSON landing tables that used to
-- be created here have MOVED to snowflake/setup/016_create_raw_landing.sql, into
-- the RAW_LANDING schema (the physical ingestion landing). BRONZE.BR_RAW_X12_*
-- are now dbt model outputs. This script keeps only the imperative stage + file
-- format that DCM/dbt do not own.
--
-- Flow: Synthea CSV --(synthea_to_x12.py)--> .x12 files
--       --> PUT @STG_X12_837 + COPY INTO RAW_LANDING.BR_RAW_X12_837 (raw, as-is)
--       --> Airflow DAG x12_to_json_bronze: x12tojson (moov-io/x12) per row
--       --> RAW_LANDING.BR_RAW_X12_CLAIM_JSON.payload (VARIANT) --> dbt canonical.
--
-- Data is SYNTHETIC -- not real CMS/Medicare/Medicaid/PHI.
-- =============================================================================
SET claims_db = 'CLAIMS_DEV';
USE ROLE CLAIMS_SYSADMIN;
USE DATABASE IDENTIFIER($claims_db);

-- ---- internal stage + whole-file format for raw X12 ------------------------
USE SCHEMA RAW;

-- Whole-file text format: the entire .x12 file lands as a single field so the
-- raw EDI is stored verbatim ("as is").
CREATE FILE FORMAT IF NOT EXISTS FF_X12_RAW
  TYPE = CSV
  FIELD_DELIMITER = NONE
  RECORD_DELIMITER = NONE
  SKIP_HEADER = 0
  FIELD_OPTIONALLY_ENCLOSED_BY = NONE
  COMMENT = 'Reads an entire X12 EDI file as one VARCHAR field (raw, as-is).';

CREATE STAGE IF NOT EXISTS STG_X12_837
  FILE_FORMAT = FF_X12_RAW
  COMMENT = 'Internal stage for raw Synthea-derived X12 837P files.';

GRANT READ, WRITE ON STAGE STG_X12_837 TO ROLE CLAIMS_LOADER;
GRANT READ ON STAGE STG_X12_837 TO ROLE CLAIMS_TRANSFORMER;
GRANT USAGE ON FILE FORMAT FF_X12_RAW TO ROLE CLAIMS_LOADER;

-- ---- X12 landing tables (BR_RAW_X12_837 / BR_RAW_X12_CLAIM_JSON) ------------
-- MOVED to snowflake/setup/016_create_raw_landing.sql (RAW_LANDING schema).
-- BRONZE.BR_RAW_X12_* are now dbt model outputs; RAW_LANDING.BR_RAW_X12_* are
-- the physical landing targets. Grants on those tables live in 016.

-- ---- Example raw ingest (whole file as one x12_raw value) -------------------
-- PUT 'file://data_generator/synthea/output/x12/claims_837p_0001.x12' @RAW.STG_X12_837
--   OVERWRITE=TRUE AUTO_COMPRESS=TRUE;
-- COPY INTO RAW_LANDING.BR_RAW_X12_837
--   (bronze_event_id, source_system, source_file_name, source_file_row_number,
--    event_type, x12_raw, payload_hash, record_status)
-- FROM (
--   SELECT SHA2(METADATA$FILENAME,256), 'SYNTHEA_X12_837P', METADATA$FILENAME, 1,
--          'X12_837P', $1, SHA2($1,256), 'LANDED'
--   FROM @RAW.STG_X12_837 (FILE_FORMAT => RAW.FF_X12_RAW)
-- );
-- (Or use snowflake/load/load_x12_raw.py / the Airflow DAG.)
