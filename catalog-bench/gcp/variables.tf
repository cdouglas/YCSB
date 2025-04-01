variable "gcp_project" {
  type        = string
  description = "GCP project ID"
}

variable "gcp_region" {
  type        = string
  description = "GCP region to deploy the instance"
}

variable "gcp_zone" {
  type        = string
  description = "GCP zone to deploy the instance"
}

variable "gcs_bucket_name" {
  type        = string
  description = "GCS bucket name for benchmark results"
}

variable "ssh_user" {
  type        = string
  description = "Username for SSH access"
  default     = "gcpuser"
}

variable "ssh_public_key_path" {
  type        = string
  description = "Path to the public SSH key file"
}

variable "docker_image" {
  type        = string
  description = "Docker image for the benchmark"
}
