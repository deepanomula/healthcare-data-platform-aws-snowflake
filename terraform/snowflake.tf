# =====================================================================
# 1. PROVIDERS & DATA EXTRACTORS
# =====================================================================
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = "~> 1.0"
    }
  }
}

data "aws_caller_identity" "current" {}

# =====================================================================
# 2. STATEFUL COMPUTE & STORAGE PLATFORM TOPOLOGY
# =====================================================================
resource "snowflake_warehouse" "ingestion_wh" {
  name           = "INGESTION_WH"
  warehouse_size = "X-SMALL"
  auto_suspend   = 60 # Instantly scales down after 1 minute of absolute silence
  auto_resume    = true
}

resource "snowflake_database" "healthcare_db" {
  name = "HEALTHCARE_RECORDS_DB"
}

resource "snowflake_schema" "clinical_stage" {
  database = snowflake_database.healthcare_db.name
  name     = "CLINICAL_STAGE"
}

resource "snowflake_schema" "clinical_gold" {
  database = snowflake_database.healthcare_db.name
  name     = "CLINICAL_GOLD"
}

# =====================================================================
# 3. THE DETERMINISTIC CROSS-CLOUD CRYPTOGRAPHIC HANDSHAKE
# =====================================================================
locals {
  snowflake_role_name = "university-vitals-snowflake-silver-role"
  calculated_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.snowflake_role_name}"
}

resource "snowflake_storage_integration" "s3_silver_integration" {
  name                      = "S3_SILVER_STORAGE_INTEGRATION"
  type                      = "EXTERNAL_STAGE"
  enabled                   = true
  storage_provider          = "S3"
  storage_aws_role_arn      = local.calculated_role_arn
  storage_allowed_locations = ["s3://university-vitals-data-lake-silver/silver-vitals/"]
}

# AWS Side of the Gate: Built seamlessly inside the same deployment sweep
resource "aws_iam_role" "snowflake_silver_access_role" {
  name = local.snowflake_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SnowflakeIdentityFederationTrust"
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Principal = {
          AWS = snowflake_storage_integration.s3_silver_integration.storage_aws_iam_user_arn
        }
        Condition = {
          StringEquals = {
            "sts:ExternalId" = snowflake_storage_integration.s3_silver_integration.storage_aws_external_id
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "snowflake_silver_s3_policy" {
  name = "university-vitals-snowflake-silver-s3-permissions"
  role = aws_iam_role.snowflake_silver_access_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::university-vitals-data-lake-silver",
          "arn:aws:s3:::university-vitals-data-lake-silver/silver-vitals/*"
        ]
      }
    ]
  })
}

# =====================================================================
# 4. REUSABLE STAGE POINTER OVER S3 PREFIX
# =====================================================================
resource "snowflake_stage" "silver_s3_stage" {
  name                = "SILVER_S3_STAGE"
  database            = snowflake_database.healthcare_db.name
  schema              = snowflake_schema.clinical_stage.name
  url                 = "s3://university-vitals-data-lake-silver/silver-vitals/"
  storage_integration = snowflake_storage_integration.s3_silver_integration.name

  depends_on = [
    aws_iam_role.snowflake_silver_access_role,
    aws_iam_role_policy.snowflake_silver_s3_policy
  ]
}