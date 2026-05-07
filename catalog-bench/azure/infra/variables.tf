variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "location" {
  description = "Azure region to deploy resources in"
  type        = string
}

variable "storage_account_name" {
  description = "Base name (prefix) for the Premium block-blob SA; a random suffix is appended"
  type        = string
}

variable "storage_container_name" {
  description = "Container on the Premium SA"
  type        = string
}

variable "standard_storage_account_name" {
  description = "Standard ADLS storage account name (adopted via terraform import)"
  type        = string
  default     = "lstnsgym"
}

variable "standard_storage_account_resource_group" {
  description = "Resource group of the Standard ADLS account"
  type        = string
  default     = "lst-consistency"
}

variable "standard_storage_container_name" {
  description = "Container on the Standard SA"
  type        = string
  default     = "lst-ns-consistency"
}

variable "sas_expiry_duration" {
  description = "How long the SAS token should be valid (e.g., '48h', '7d')"
  type        = string
  default     = "24h"
}