variable "project_name" {
  description = "Project name used for backend resource naming"
  type        = string
  default     = "capstone-phoenix"
}

variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment (e.g., dev, staging, prod)"
  type        = string
  default     = "production"
}