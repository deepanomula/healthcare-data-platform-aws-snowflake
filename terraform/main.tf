# ==========================================
# 1. S3 STORAGE TIERS (Bronze & Silver)
# ==========================================
resource "aws_s3_bucket" "bronze_bucket" {
  bucket        = "university-vitals-data-lake-bronze"
  force_destroy = true
}

resource "aws_s3_bucket" "silver_bucket" {
  bucket        = "university-vitals-data-lake-silver"
  force_destroy = true
}

# ==========================================
# 2. INGESTION SHOCK-ABSORBER: STANDARD SQS QUEUE
# ==========================================
resource "aws_sqs_queue" "ingestion_queue" {
  # 💡 Removed the ".fifo" suffix and turned off FIFO configurations
  name                        = "university-vitals-ingestion-queue"
  visibility_timeout_seconds  = 300 
}

# Allow S3 Buckets to push event notifications to our SQS Queue
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

# ==========================================
# 3. EVENT NOTIFICATION TRIGGER
# ==========================================
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.bronze_bucket.id

  queue {
    # 💡 Pointing to the updated standard queue mapping
    queue_arn     = aws_sqs_queue.ingestion_queue.arn
    events        = ["s3:ObjectCreated:*"]
    filter_suffix = ".csv"
  }
}

# ==========================================
# 4. COMPUTE ORCHESTRATION: ROUTER LAMBDA
# ==========================================
resource "aws_lambda_function" "router_lambda" {
  filename      = "router_payload.zip" # Packaged via your CI/CD pipeline
  function_name = "university-vitals-router-handler"
  role          = aws_iam_role.lambda_execution_role.arn
  handler       = "router_handler.lambda_handler"
  runtime       = "python3.11"
  timeout       = 60

  environment {
    variables = {
      TRANSFORMER_LAMBDA_NAME = aws_lambda_function.transformer_lambda.function_name
      GLUE_JOB_NAME           = aws_glue_job.spark_transform_job.name
    }
  }
}

# Connect SQS FIFO Queue directly as the trigger source for the Router Lambda
resource "aws_lambda_event_source_mapping" "sqs_to_router" {
  event_source_arn = aws_sqs_queue.ingestion_fifo_queue.arn
  function_name    = aws_lambda_function.router_lambda.arn
  batch_size       = 10 # Process up to 10 file events at a time
}

# ==========================================
# 5. DOWNSTREAM COMPUTE: TRANSFORMER LAMBDA
# ==========================================
resource "aws_lambda_function" "transformer_lambda" {
  filename      = "transformer_payload.zip"
  function_name = "university-vitals-transformer-lambda"
  role          = aws_iam_role.lambda_execution_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.11"
  timeout       = 300 # 5-minute threshold capacity

  environment {
    variables = {
      SECRET_SALT = "TexasLonghorns2026!#CloudDataPlatform"
    }
  }
}

# ==========================================
# 6. HEAVY COMPUTE: AWS GLUE SPARK JOB
# ==========================================
resource "aws_glue_job" "spark_transform_job" {
  name     = "university-vitals-glue-spark-job"
  role_arn = aws_iam_role.glue_execution_role.arn
  command {
    script_location = "s3://${aws_s3_bucket.silver_bucket.id}/scripts/glue_spark_job.py"
    python_version  = "3"
  }
  default_arguments = {
    "--job-language"        = "python"
    "--continuous-log"      = "true"
    "--enable-metrics"      = "true"
  }
}

# ==========================================
# 7. SECURITY & GOVERNANCE: IAM SECURITY ROLES
# ==========================================
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

# Attach core permissions to the Lambda role (S3 data access, SQS polling, and internal Lambda/Glue triggers)
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
        Resource = [aws_sqs_queue.ingestion_fifo_queue.arn]
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

# Glue Exec Role (similar basic permissions but explicitly targeting glue actions)
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