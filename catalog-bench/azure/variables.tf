variable "azure_region" {
  type = string
}

variable "ssh_public_key_path" {
  type = string
}

variable "docker_image" {
  type        = string
  description = "Docker image to run benchmark"
}

variable "storage_account_name" {
  type = string
}

variable "storage_container_name" {
  type = string
}

variable "storage_account_resource_group" {
  type        = string
  description = "The resource group containing the existing storage account"
}


