variable "azure_region" {
  description = "Azure region where resources will be deployed"
  type        = string
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key used to access the VM"
  type        = string
}

variable "docker_image" {
  description = "Docker image to run the benchmark"
  type        = string
}

variable "storage_account_name" {
  description = "Name of the existing Azure Storage Account to use for benchmark results"
  type        = string
}

variable "storage_container_name" {
  description = "Name of the container in the Azure Storage Account"
  type        = string
}
