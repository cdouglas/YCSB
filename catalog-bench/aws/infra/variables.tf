variable "aws_region" {
  type = string
}

variable "aws_profile" {
  type = string
}

variable "s3_bucket_name" {
  type        = string
  description = "Standard S3 bucket name"
}

variable "s3_express_bucket_name" {
  type        = string
  description = "S3 Express One Zone bucket name (must include the --<azid>--x-s3 suffix)"
  default     = "lst-pbafvfgrapl--usw2-az3--x-s3"
}

variable "s3_express_az_id" {
  type        = string
  description = "Availability Zone ID for the S3 Express bucket (e.g., usw2-az3)"
  default     = "usw2-az3"
}
