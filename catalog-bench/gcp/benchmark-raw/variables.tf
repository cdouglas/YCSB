variable "gcp_project" {
  type        = string
  description = "GCP project ID"
  default     = "lst-consistency"  # Your project ID
}

variable "gcp_region" {
  type        = string
  description = "GCP region to deploy the instance"
  default     = "us-west1"  # Your preferred region
}

variable "gcp_zone" {
  type        = string
  description = "GCP zone to deploy the instance"
  default     = "us-west1-a"  # A specific zone in your region
}

variable "gcp_bucket_name" {
  type        = string
  description = "GCS bucket name for benchmark results"
  default     = "lst-consistency"  # Your existing bucket
}

variable "ssh_user" {
  type        = string
  description = "Username for SSH access"
  default     = "ubuntu"
}

variable "ssh_public_key_path" {
  type        = string
  description = "Path to the public SSH key file"
}

variable "docker_image" {
  type        = string
  description = "Docker image for the benchmark"
  # Replace with your actual image
  default     = "gcr.io/lst-consistency/ycsb-benchmark:latest"
}

variable "instance_type" {
  type        = string
  description = "VM instance type"
}
