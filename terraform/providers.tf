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

# 💡 No custom input variables or mappings needed! 
# The v1.0 driver reads standard SNOWFLAKE_ env vars automatically.
provider "snowflake" {}