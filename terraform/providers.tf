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

# 💡 Define parameters for both the structural validation check and the host path
variable "snowflake_account"  { type = string }
variable "snowflake_host"     { type = string }
variable "snowflake_user"     { type = string }
variable "snowflake_password" { type = string }

provider "snowflake" {
  account  = var.snowflake_account
  host     = var.snowflake_host
  user     = var.snowflake_user
  password = var.snowflake_password
}