terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Best Practice: Store your state file remotely in S3 with DynamoDB locking
  # prevents multiple developers/pipelines from breaking infrastructure concurrently
  backend "s3" {
    bucket         = "university-vitals-tf-state-bucket"
    key            = "prod/healthcare-platform/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-locking"
  }
}

provider "aws" {
  region = var.aws_region
}