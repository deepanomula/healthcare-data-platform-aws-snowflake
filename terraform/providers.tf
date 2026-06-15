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
      source  = "Snowflake-Labs/snowflake"
      version = "~> 1.0" 
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# 1. Add a specific host string input variable
variable "snowflake_organization" { type = string }
variable "snowflake_account_name"{ type = string }
variable "snowflake_host"        { type = string } # 💡 Added this variable
variable "snowflake_user"        { type = string }
variable "snowflake_password"    { type = string }

# 2. Add the host direct mapping line to the provider schema
provider "snowflake" {
  organization_name = var.snowflake_organization
  account_name      = var.snowflake_account_name
  host              = var.snowflake_host        # 💡 Maps directly to your endpoint bypass
  user              = var.snowflake_user
  password          = var.snowflake_password
}