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
      source  = "snowflakedb/snowflake"
      version = "~> 1.0" 
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# =====================================================================
# THE FIXED SNOWFLAKE ORG-BASED AUTHENTICATION GATEWAY
# =====================================================================
provider "snowflake" {
  organization_name = "PYDONEM"
  account_name      = var.SNOWFLAKE_ACCOUNT
  
  user              = var.SNOWFLAKE_USER
  authenticator     = "SNOWFLAKE"
  password          = var.SNOWFLAKE_PASSWORD
}