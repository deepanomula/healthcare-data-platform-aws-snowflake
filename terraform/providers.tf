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

variable "snowflake_organization_name" { type = string }
variable "snowflake_account_name"      { type = string }
variable "snowflake_host"              { type = string } # Ensure this is declared
variable "snowflake_user"              { type = string }
variable "snowflake_password"          { type = string }

provider "snowflake" {
  organization_name = var.snowflake_organization_name
  account_name      = var.snowflake_account_name
  host              = var.snowflake_host # Explicitly forces the direct routing path
  user              = var.snowflake_user
  password          = var.snowflake_password
}
