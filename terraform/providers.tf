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

# 1. Map all parameters required by the modern v1.0 engine validation rules
variable "snowflake_organization" { type = string }
variable "snowflake_account_name" { type = string }
variable "snowflake_host"         { type = string }
variable "snowflake_user"         { type = string }
variable "snowflake_password"     { type = string }

# 2. Configure the provider block with all mandatory arguments
provider "snowflake" {
  organization_name = var.snowflake_organization
  account_name      = var.snowflake_account_name
  host              = var.snowflake_host
  user              = var.snowflake_user
  password          = var.snowflake_password
}