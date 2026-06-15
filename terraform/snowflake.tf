# ==========================================
# 1. CORE WAREHOUSE & DATABASE STRUCTURING
# ==========================================
resource "snowflake_database" "healthcare_db" {
  name    = "UNIVERSITY_HEALTHCARE_DB"
  comment = "Data platform warehouse for university vitals ingestion"
}

resource "snowflake_schema" "silver_schema" {
  database = snowflake_database.healthcare_db.name
  name     = "SILVER_STAGING"
}

resource "snowflake_warehouse" "ingest_wh" {
  name           = "HEALTHCARE_INGEST_WH"
  warehouse_size = "XSMALL"
  auto_suspend   = 60 # Shuts down compute after 1 minute of inactivity to save credits
  auto_resume    = true
}

# ==========================================
# 2. FILE PROCESSING FORMAT
# ==========================================
resource "snowflake_file_format" "csv_format" {
  name        = "CSV_FORMAT"
  database    = snowflake_database.healthcare_db.name
  schema      = snowflake_schema.silver_schema.name
  format_type = "CSV"
  
  field_delimiter      = ","
  skip_header          = 1
  field_optionally_enclosed_by = "\""
  null_if              = ("\\N", "NULL", "")
}

# ==========================================
# 3. INTERVIEW-READY TIP: EXTERNAL AWS S3 STAGE
# ==========================================
# This creates a reference boundary pointing straight to your AWS Silver Bucket
resource "snowflake_stage" "s3_silver_stage" {
  name        = "S3_SILVER_STAGE"
  database    = snowflake_database.healthcare_db.name
  schema      = snowflake_schema.silver_schema.name
  url         = "s3://university-vitals-data-lake-silver/transformed-data/"
  file_format = "${snowflake_database.healthcare_db.name}.${snowflake_schema.silver_schema.name}.${snowflake_file_format.csv_format.name}"
}