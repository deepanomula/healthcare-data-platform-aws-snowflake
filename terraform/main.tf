# =====================================================================
# DATA & VARIABLES (Governance)
# =====================================================================
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

variable "secret_salt" {
  type        = string
  description = "Cryptographic salt used for enterprise data masking layers"
  default     = "TexasLonghorns2026!#CloudDataPlatform"
  sensitive   = true 
}

# =====================================================================
# 1. S3 STORAGE TIERS (Bronze, Silver, & Config)
# =====================================================================
resource "aws_s3_bucket" "bronze_bucket" {
  bucket        = "university-vitals-data-lake-bronze"
  force_destroy = true
}

resource "aws_s3_bucket" "silver_bucket" {
  bucket        = "university-vitals-data-lake-silver"
  force_destroy = true
}

resource "aws_s3_bucket" "config_bucket" {
  bucket        = "university-vitals-pipeline-config"
  force_destroy = true
}

# =====================================================================
# 2. INGESTION SHOCK-ABSORBER: SQS FIFO TIERS
# =====================================================================
resource "aws_sqs_queue" "ingestion_dlq" {
  name                        = "university-vitals-ingestion-queue-dlq.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
}

resource "aws_sqs_queue" "ingestion_queue" {
  name                        = "university-vitals-ingestion-queue"
  fifo_queue                  = false
  visibility_timeout_seconds  = 300 

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.ingestion_dlq.arn
    maxReceiveCount     = 2 
  })
}

resource "aws_sqs_queue_policy" "sqs_policy" {
  queue_url = aws_sqs_queue.ingestion_queue.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.ingestion_queue.arn
        Condition = {
          ArnEquals = { "aws:SourceArn" = aws_s3_bucket.bronze_bucket.arn }
        }
      }
    ]
  })
}

resource "aws_s3_bucket_notification" "bronze_bucket_notification" {
  bucket = aws_s3_bucket.bronze_bucket.id

  queue {
    queue_arn = aws_sqs_queue.ingestion_queue.arn
    events    = ["s3:ObjectCreated:*"]
  }
}

# =====================================================================
# 3. ROUTER LAMBDA (Multi-Threaded Orchestrator)
# =====================================================================
resource "aws_lambda_function" "router_lambda" {
  filename      = "router_payload.zip" 
  function_name = "university-vitals-router-handler"
  role          = aws_iam_role.lambda_execution_role.arn
  handler       = "router_handler.lambda_handler"
  runtime       = "python3.11"
  timeout       = 300 

  environment {
    variables = {
      TRANSFORMER_LAMBDA_NAME = aws_lambda_function.transformer_lambda.function_name
      GLUE_JOB_NAME           = aws_glue_job.spark_transform_job.name
      SECRET_SALT             = var.secret_salt
    }
  }
}

resource "aws_lambda_event_source_mapping" "sqs_to_router" {
  event_source_arn = aws_sqs_queue.ingestion_queue.arn
  function_name    = aws_lambda_function.router_lambda.arn
  batch_size       = 10 
}

# =====================================================================
# 4. TRANSFORMER LAMBDA (Micro-Batch Compute Tier)
# =====================================================================
resource "aws_lambda_function" "transformer_lambda" {
  filename      = "transformer_payload.zip"
  function_name = "university-vitals-transformer-lambda"
  role          = aws_iam_role.lambda_execution_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.11"
  timeout       = 300 
  reserved_concurrent_executions = 10

  environment {
    variables = {
      SECRET_SALT = var.secret_salt 
    }
  }
}

# =====================================================================
# 5. AWS GLUE SPARK JOB (Heavy Macro-Batch Compute Tier)
# =====================================================================
resource "aws_glue_job" "spark_transform_job" {
  name         = "university-vitals-glue-spark-job"
  role_arn     = aws_iam_role.glue_execution_role.arn
  max_capacity = 10 
  timeout      = 60 

  command {
    script_location = "s3://${aws_s3_bucket.config_bucket.id}/scripts/glue_spark_job.py"
    python_version  = "3"
  }
  
  execution_property {
    max_concurrent_runs = 1 
  }
  
  default_arguments = {
    "--job-language"        = "python"
    "--continuous-log"      = "true"
    "--enable-metrics"      = "true"
    "--secret_salt"         = var.secret_salt
  }
}

# =====================================================================
# 6. INTERNAL AWS COMPUTATION SECURITY ROLES
# =====================================================================
resource "aws_iam_role" "lambda_execution_role" {
  name = "university-vitals-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "university-vitals-lambda-permissions"
  role = aws_iam_role.lambda_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = ["*"]
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = ["*"]
      },
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = ["*"]
      },
      {
        Effect   = "Allow"
        Action   = ["glue:StartJobRun"]
        Resource = ["*"]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["arn:aws:logs:*:*:*"]
      }
    ]
  })
}

resource "aws_iam_role" "glue_execution_role" {
  name = "university-vitals-glue-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_s3_policy" {
  name = "university-vitals-glue-s3-access"
  role = aws_iam_role.glue_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.bronze_bucket.arn,
          "${aws_s3_bucket.bronze_bucket.arn}/*",
          aws_s3_bucket.silver_bucket.arn,
          "${aws_s3_bucket.silver_bucket.arn}/*",
          aws_s3_bucket.config_bucket.arn,
          "${aws_s3_bucket.config_bucket.arn}/*"
        ]
      }
    ]
  })
}