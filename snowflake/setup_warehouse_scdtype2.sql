-- ============================================================================
-- GIT MIGRATION ARCHITECTURAL SCRIPT
-- TARGET DATABASE: HEALTHCARE_RECORDS_DB
-- TARGET SCHEMAS: CLINICAL_STAGE & CLINICAL_GOLD
-- ============================================================================
USE DATABASE HEALTHCARE_RECORDS_DB;

-- ============================================================================
-- 1. BASE DATA STRUCTS (The Single Shared Staging Landing Pad)
-- ============================================================================
USE SCHEMA CLINICAL_STAGE;

CREATE TABLE IF NOT EXISTS CLINICAL_STAGE.SILVER_VITALS_STAGING (
    ENCOUNTER_ID      VARCHAR,
    HASHED_PATIENT_ID VARCHAR,
    HEART_RATE        INT,
    BLOOD_PRESSURE    VARCHAR,
    TEMPERATURE       FLOAT,
    SOURCE_VENDOR     VARCHAR,
    LINEAGE_FILE_UUID VARCHAR,
    INGESTED_AT       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ============================================================================
-- 2. FILE FORMAT ARCHITECTURES
-- ============================================================================
CREATE OR REPLACE FILE FORMAT CLINICAL_STAGE.LAMBDA_CSV_FORMAT
  TYPE = 'CSV'
  FIELD_DELIMITER = ','
  SKIP_HEADER = 1
  NULL_IF = ('NULL', '', 'NONE')
  EMPTY_FIELD_AS_NULL = TRUE;

CREATE OR REPLACE FILE FORMAT CLINICAL_STAGE.GLUE_PARQUET_FORMAT
  TYPE = 'PARQUET'
  COMPRESSION = 'SNAPPY';

-- ============================================================================
-- 3. DUAL-LANE REAL-TIME EVENT INGESTION PIPES (Funneling into ONE table)
-- ============================================================================
-- Lane A: Maps flat incoming CSV streams out of the Lambda worker tier
CREATE OR REPLACE PIPE CLINICAL_STAGE.LAMBDA_CSV_SNOWPIPE
  AUTO_INGEST = TRUE
  AS
  COPY INTO CLINICAL_STAGE.SILVER_VITALS_STAGING (
      ENCOUNTER_ID, HASHED_PATIENT_ID, HEART_RATE, BLOOD_PRESSURE, TEMPERATURE, SOURCE_VENDOR, LINEAGE_FILE_UUID
  )
  FROM @CLINICAL_STAGE.SILVER_S3_STAGE
  FILE_FORMAT = (FORMAT_NAME = 'CLINICAL_STAGE.LAMBDA_CSV_FORMAT')
  PATTERN = '.*_clean\\.csv';

-- Lane B: Maps deeply nested, compressed columns from Glue's distributed Spark engines
CREATE OR REPLACE PIPE CLINICAL_STAGE.GLUE_PARQUET_SNOWPIPE
  AUTO_INGEST = TRUE
  AS
  COPY INTO CLINICAL_STAGE.SILVER_VITALS_STAGING (
      ENCOUNTER_ID, HASHED_PATIENT_ID, HEART_RATE, BLOOD_PRESSURE, TEMPERATURE, SOURCE_VENDOR, LINEAGE_FILE_UUID
  )
  FROM (
      SELECT 
          $1:encounter_id::VARCHAR,
          $1:hashed_patient_id::VARCHAR,
          $1:heart_rate::INT,
          $1:blood_pressure::VARCHAR,
          $1:temperature::FLOAT,
          $1:source_vendor::VARCHAR,
          $1:lineage_file_uuid::VARCHAR
      FROM @CLINICAL_STAGE.SILVER_S3_STAGE
  )
  FILE_FORMAT = (FORMAT_NAME = 'CLINICAL_STAGE.GLUE_PARQUET_FORMAT')
  PATTERN = '.*\\.parquet';

-- ============================================================================
-- 4. CHANGE DATA CAPTURE (CDC) LAYER
-- ============================================================================
-- This single stream monitors our shared staging landing pad for continuous appends
CREATE OR REPLACE STREAM CLINICAL_STAGE.SILVER_VITALS_STREAM 
ON TABLE CLINICAL_STAGE.SILVER_VITALS_STAGING
APPEND_ONLY = TRUE;

-- ============================================================================
-- GOLD ENTERPRISE WAREHOUSE LAYER: HISTORICAL DIMENSION (SCD TYPE 2)
-- ============================================================================
USE DATABASE HEALTHCARE_RECORDS_DB;
USE SCHEMA CLINICAL_GOLD;

CREATE OR REPLACE TABLE CLINICAL_GOLD.DIM_PATIENT_VITALS_HIST (
    VITALS_HASH_KEY   VARCHAR, -- Unique surrogate hash tracking this specific data state
    ENCOUNTER_ID      VARCHAR, -- The natural business key
    HASHED_PATIENT_ID VARCHAR,
    HEART_RATE        INT,
    BLOOD_PRESSURE    VARCHAR,
    TEMPERATURE       FLOAT,
    SOURCE_VENDOR     VARCHAR,
    LINEAGE_FILE_UUID VARCHAR,
    
    -- 💡 SCD Type 2 Audit Columns
    START_TIME        TIMESTAMP_NTZ,
    END_TIME          TIMESTAMP_NTZ,
    IS_CURRENT        BOOLEAN,
    
    PRIMARY KEY (VITALS_HASH_KEY)
) 
CLUSTER BY (SOURCE_VENDOR, ENCOUNTER_ID, IS_CURRENT); -- Highly optimized for looking up active records

USE DATABASE HEALTHCARE_RECORDS_DB;
USE SCHEMA CLINICAL_STAGE;

-- ============================================================================
-- SERVERLESS ORCHESTRATION & SCD TYPE 2 ENGINES
-- ============================================================================
CREATE OR REPLACE TASK CLINICAL_STAGE.ORCHESTRATE_GOLD_VITALS_SCD2_MERGE
USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
SCHEDULE = 'USING CRON */5 * * * * UTC' -- Evaluates every 5 minutes
WHEN SYSTEM$STREAM_HAS_DATA('CLINICAL_STAGE.SILVER_VITALS_STREAM')
AS
-- 💡 Multi-Table Insert Pattern to handle concurrent inserts and updates
INSERT ALL
    -- BRANCH A: Expire the existing record if an incoming change matches the natural key
    WHEN action = 'UPDATE' THEN
        INTO CLINICAL_GOLD.DIM_PATIENT_VITALS_HIST (
            VITALS_HASH_KEY, ENCOUNTER_ID, HASHED_PATIENT_ID, HEART_RATE, BLOOD_PRESSURE, 
            TEMPERATURE, SOURCE_VENDOR, LINEAGE_FILE_UUID, START_TIME, END_TIME, IS_CURRENT
        )
        VALUES (
            target_hash_key, ENCOUNTER_ID, HASHED_PATIENT_ID, target_heart_rate, target_blood_pressure,
            target_temperature, SOURCE_VENDOR, target_file_uuid, target_start_time, stream_ingested_at, FALSE
        )
        
    -- BRANCH B: Insert the fresh record as the absolute current active state
    WHEN action = 'INSERT' OR action = 'UPDATE' THEN
        INTO CLINICAL_GOLD.DIM_PATIENT_VITALS_HIST (
            VITALS_HASH_KEY, ENCOUNTER_ID, HASHED_PATIENT_ID, HEART_RATE, BLOOD_PRESSURE, 
            TEMPERATURE, SOURCE_VENDOR, LINEAGE_FILE_UUID, START_TIME, END_TIME, IS_CURRENT
        )
        VALUES (
            MD5(CONCAT(ENCOUNTER_ID, '_', SOURCE_VENDOR, '_', stream_ingested_at)), ENCOUNTER_ID, HASHED_PATIENT_ID, 
            HEART_RATE, BLOOD_PRESSURE, TEMPERATURE, SOURCE_VENDOR, LINEAGE_FILE_UUID, stream_ingested_at, NULL, TRUE
        )

SELECT 
    source.ENCOUNTER_ID,
    source.HASHED_PATIENT_ID,
    source.HEART_RATE,
    source.BLOOD_PRESSURE,
    source.TEMPERATURE,
    source.SOURCE_VENDOR,
    source.LINEAGE_FILE_UUID,
    source.INGESTED_AT as stream_ingested_at,
    target.VITALS_HASH_KEY as target_hash_key,
    target.HEART_RATE as target_heart_rate,
    target.BLOOD_PRESSURE as target_blood_pressure,
    target.TEMPERATURE as target_temperature,
    target.LINEAGE_FILE_UUID as target_file_uuid,
    target.START_TIME as target_start_time,
    -- Determine whether we are inserting a brand new record, or expiring an old state
    CASE 
        WHEN target.ENCOUNTER_ID IS NULL THEN 'INSERT'
        ELSE 'UPDATE'
    END as action
FROM (
    -- Window deduplication to guard against batch replication errors
    SELECT * FROM CLINICAL_STAGE.SILVER_VITALS_STREAM
    QUALIFY ROW_NUMBER() OVER (PARTITION BY ENCOUNTER_ID ORDER BY INGESTED_AT DESC) = 1
) source
LEFT JOIN CLINICAL_GOLD.DIM_PATIENT_VITALS_HIST target
    ON source.ENCOUNTER_ID = target.ENCOUNTER_ID
    AND target.IS_CURRENT = TRUE; -- Only join against what is currently flagged active

-- Resume the task engine immediately upon creation
ALTER TASK CLINICAL_STAGE.ORCHESTRATE_GOLD_VITALS_SCD2_MERGE RESUME;