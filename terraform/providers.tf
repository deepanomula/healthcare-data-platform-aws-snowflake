terraform {
  required_version = ">= 1.5.0"
  
  backend "s3" {
    bucket       = "university-vitals-tf-state-bucket"
    key          = "healthcare-pipeline/terraform.tfstate"
    region       = "us-east-1"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    snowflake = {
      # 💡 Updated to the modern official registry namespace
      source  = "snowflakedb/snowflake"
      version = "~> 1.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# 1. Declare a single, unified Data Source Name variable
variable "snowflake_dsn" { type = string }

# 2. Pass it directly to the provider
provider "snowflake" {
  dsn = var.snowflake_dsn
}