
variable "aws_region" {
  type = string
}

variable "aws_profile" {
  type = string
}

variable "s3_bucket_name" {
  type        = string
  description = "Name of the S3 bucket to create for benchmarking"
}
