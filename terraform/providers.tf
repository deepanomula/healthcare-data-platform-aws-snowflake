terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    snowflake = {
      # 💡 Ensure this points strictly to the verified community org
      source  = "Snowflake-Labs/snowflake"
      version = "~> 1.0" 
    }
  }

  # Best Practice: Store your state file remotely in S3 with DynamoDB locking
  # prevents multiple developers/pipelines from breaking infrastructure concurrently
  backend "s3" {
    bucket         = "university-vitals-tf-state-bucket"
    key            = "prod/healthcare-platform/terraform.tfstate"
    region         = "us-east-1"
  }
}

provider "aws" {
  region = var.aws_region
}

provider "snowflake" {
  # These will be supplied securely by your GitHub Actions runner secrets
}

# 1. Map incoming environment variables to explicit inputs
variable "snowflake_account" { type = string }
variable "snowflake_user"    { type = string }
variable "snowflake_password"{ type = string }

# 2. Feed the variables directly into the provider config
provider "snowflake" {
  account  = var.snowflake_account
  user     = var.snowflake_user
  password = var.snowflake_password
}