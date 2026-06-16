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

variable "snowflake_account_name" { type = string }
variable "snowflake_user"         { type = string }
variable "snowflake_password"     { type = string }

provider "snowflake" {
  # 💡 By providing ONLY the account_name variable formatted cleanly, 
  # we prevent the v1.0 driver from auto-generating a broken URL prefix.
  account_name = var.snowflake_account_name
  user         = var.snowflake_user
  password     = var.snowflake_password
}