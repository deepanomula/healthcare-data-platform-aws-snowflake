-- ============================================================================
-- 1. DATABASE & WAREHOUSE CONFIGURATION (The Compute and Storage Layers)
-- ============================================================================
CREATE OR REPLACE DATABASE HEALTHCARE_RECORDS_DB;
CREATE OR REPLACE WAREHOUSE INGESTION_WH WITH WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE;

USE DATABASE HEALTHCARE_RECORDS_DB;
USE WAREHOUSE INGESTION_WH;

CREATE OR REPLACE SCHEMA CLINICAL_STAGE;

-- ============================================================================
-- 2. SILVER STAGING LAYER (Append-Only Target for Snowpipe Ingestion)
-- ============================================================================
CREATE OR REPLACE TABLE CLINICAL_STAGE.SILVER_VITALS_STAGING (
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
-- 3. CHANGE DATA CAPTURE (CDC): FLOW PATTERN VIA STREAMS
-- ============================================================================
-- This stream acts as an automated bookmarker tracking APPENDS to staging
CREATE OR REPLACE STREAM CLINICAL_STAGE.SILVER_VITALS_STREAM 
ON TABLE CLINICAL_STAGE.SILVER_VITALS_STAGING
APPEND_ONLY = TRUE;

-- ============================================================================
-- 4. GOLD ANALYTICAL LAYER (The Target Production Warehouse Tables)
-- ============================================================================
CREATE OR REPLACE SCHEMA CLINICAL_GOLD;

CREATE OR REPLACE TABLE CLINICAL_GOLD.FACT_PATIENT_VITALS (
    VITALS_KEY        VARCHAR, -- Synthetic surrogate hash key
    ENCOUNTER_ID      VARCHAR,
    HASHED_PATIENT_ID VARCHAR,
    HEART_RATE        INT,
    BLOOD_PRESSURE    VARCHAR,
    TEMPERATURE       FLOAT,
    SOURCE_VENDOR     VARCHAR,
    LINEAGE_FILE_UUID VARCHAR,
    UPDATED_AT        TIMESTAMP_NTZ,
    PRIMARY KEY (ENCOUNTER_ID)
) 
CLUSTER BY (SOURCE_VENDOR, TO_DATE(UPDATED_AT)); -- Performance Pruning Strategy

-- ============================================================================
-- 5. ORCHESTRATION & IDEMPOTENCY: THE CONCURRENT INTEGRITY ENGINE
-- ============================================================================
-- This serverless task runs every 5 minutes ONLY IF new data hits the Stream
CREATE OR REPLACE TASK CLINICAL_STAGE.ORCHESTRATE_GOLD_VITALS_MERGE
WAREHOUSE = 'INGESTION_WH'
SCHEDULE = 'USING CRON */5 * * * * UTC'
WHEN SYSTEM$STREAM_HAS_DATA('CLINICAL_STAGE.SILVER_VITALS_STREAM')
AS
MERGE INTO CLINICAL_GOLD.FACT_PATIENT_VITALS target
USING (
    -- Deduplicate incoming records inside the stream window block before executing merge
    SELECT 
        ENCOUNTER_ID,
        HASHED_PATIENT_ID,
        HEART_RATE,
        BLOOD_PRESSURE,
        TEMPERATURE,
        SOURCE_VENDOR,
        LINEAGE_FILE_UUID,
        INGESTED_AT
    FROM CLINICAL_STAGE.SILVER_VITALS_STREAM
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY ENCOUNTER_ID 
        ORDER BY INGESTED_AT DESC
    ) = 1
) source
ON target.ENCOUNTER_ID = source.ENCOUNTER_ID
WHEN MATCHED THEN
    UPDATE SET 
        target.HEART_RATE        = source.HEART_RATE,
        target.BLOOD_PRESSURE    = source.BLOOD_PRESSURE,
        target.TEMPERATURE       = source.TEMPERATURE,
        target.LINEAGE_FILE_UUID = source.LINEAGE_FILE_UUID,
        target.UPDATED_AT        = source.INGESTED_AT
WHEN NOT MATCHED THEN
    INSERT (VITALS_KEY, ENCOUNTER_ID, HASHED_PATIENT_ID, HEART_RATE, BLOOD_PRESSURE, TEMPERATURE, SOURCE_VENDOR, LINEAGE_FILE_UUID, UPDATED_AT)
    VALUES (
        MD5(CONCAT(source.ENCOUNTER_ID, '_', source.SOURCE_VENDOR)), -- Surrogate key generation
        source.ENCOUNTER_ID,
        source.HASHED_PATIENT_ID,
        source.HEART_RATE,
        source.BLOOD_PRESSURE,
        source.TEMPERATURE,
        source.SOURCE_VENDOR,
        source.LINEAGE_FILE_UUID,
        source.INGESTED_AT
    );

-- Crucial: Tasks are deployed in a suspended state; wake it up!
ALTER TASK CLINICAL_STAGE.ORCHESTRATE_GOLD_VITALS_MERGE RESUME;