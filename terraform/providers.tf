terraform {
  required_version = ">= 1.5.0"
  
  backend "s3" {
    bucket         = "university-vitals-tf-state-bucket" # 💡 Your remote state tracker
    key            = "prod/data-platform/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
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
# DEPLOYMENT CONFIGURATION PASS-THROUGH HOOKS (INJECTED VIA GITHUB ACTIONS)
# =====================================================================

variable "SNOWFLAKE_ACCOUNT" {
  type        = string
  description = "The target Snowflake account mapping injected via remote CI/CD secret keys."
}

variable "SNOWFLAKE_USER" {
  type        = string
  description = "The administrative execution identity user name mapped from GitHub environment parameters."
}

variable "SNOWFLAKE_PASSWORD" {
  type        = string
  sensitive   = true # 💡 Hides this secret entirely from showing up in any terminal outputs or build logs!
  description = "The cryptographic credential secret matching our production workspace identity wrapper."
}

# =====================================================================
# THE FIXED SNOWFLAKE ORG-BASED AUTHENTICATION GATEWAY
# =====================================================================
provider "snowflake" {
  organization_name = "PYDONEM"
  account_name      = "GK52446"
  
  user              = var.SNOWFLAKE_USER
  authenticator     = "SNOWFLAKE"
  password          = var.SNOWFLAKE_PASSWORD
  preview_features_enabled = ["snowflake_storage_integration_resource", 
    "snowflake_stage_resource"]
}