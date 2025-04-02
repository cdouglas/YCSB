
variable "aws_region" {
  type = string
}

variable "aws_profile" {
  type = string
}

variable "s3_bucket_name" {
  type        = string
  description = "Name of the S3 bucket created in the infra module"
}

variable "iam_instance_profile_name" {
  type        = string
  description = "Name of the IAM instance profile for EC2"
}

variable "ami_id" {
  type        = string
  description = "AMI to use for EC2 instance"
}

variable "instance_type" {
  type        = string
  default     = "t3.medium"
  description = "EC2 instance type"
}

variable "subnet_id" {
  type        = string
  description = "Subnet ID for the instance"
}

variable "ssh_key_name" {
  type        = string
  description = "SSH key name in AWS"
}

variable "ssh_private_key_path" {
  type        = string
  description = "Path to the private key for SSH provisioning"
}
