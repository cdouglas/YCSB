variable "gcp_project" {
  type = string
}

variable "gcp_region" {
  type = string
}

variable "ssh_public_key_path" {
  type = string
}

variable "ssh_user" {
  type        = string
  description = "The username for SSH access to the VM"
}

variable "docker_image" {
  type        = string
  description = "Docker image to run benchmark"
}

variable "gcs_bucket_name" {
  type        = string
  description = "GCS bucket to store benchmark results"
}
