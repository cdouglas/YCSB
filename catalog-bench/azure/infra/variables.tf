variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "location" {
  description = "Azure region to deploy resources in"
  type        = string
}

variable "storage_account_name" {
  description = "Base name of the storage account (must be globally unique, lowercase)"
  type        = string
}

variable "storage_container_name" {
  description = "Name of the blob container"
  type        = string
}

variable "sas_expiry_duration" {
  description = "How long the SAS token should be valid (e.g., '48h', '7d')"
  type        = string
  default     = "24h"
}