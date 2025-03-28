variable "aws_region" {
  type        = string
  description = "AWS region to deploy the instance"
}

variable "aws_profile" {
  type        = string
  description = "Named AWS CLI profile to use for credentials"
}

variable "ssh_public_key_path" {
  type        = string
  description = "Path to the public SSH key"
}

variable "ssh_user" {
  type        = string
  description = "Username to SSH into the EC2 instance (e.g., ubuntu)"
}

variable "docker_image" {
  type        = string
  description = "Docker image to run benchmark"
}

variable "s3_bucket_name" {
  type        = string
  description = "S3 bucket name to store benchmark results"
}
