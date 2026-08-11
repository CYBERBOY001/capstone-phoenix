terraform {
  backend "s3" {
    bucket         = "capstone-phoenix-terraform-state"
    key            = "capstone-phoenix/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "capstone-phoenix-terraform-state-lock"
    encrypt        = true
  }
}