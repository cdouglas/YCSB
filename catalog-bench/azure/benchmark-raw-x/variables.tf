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

variable "vm_size" {
  type        = string
  description = "Azure VM size for the benchmark runner"

  # Recommended VM sizes:
  # VM Size        vCPU   RAM    Notes
  # --------       ----   ----   -------------------------------
  # Standard_B2s   2      4 GiB  Burstable, low cost, good for light load
  # Standard_D4s_v3 4     16 GiB More headroom for parallel writers
  # Standard_E4s_v3 4     32 GiB Ideal for memory-heavy workloads
  # Standard_F4s_v2 4     8 GiB  High clock speed, ideal for CPU-bound tests
}
