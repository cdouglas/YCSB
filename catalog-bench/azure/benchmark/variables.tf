variable "azure_region" {
  type    = string
  default = "West US"
}

variable "ssh_public_key_path" {
  type = string
}

variable "vm_size" {
  type    = string
  default = "Standard_D16s_v3"
}

variable "adls_standard_account_name" {
  type        = string
  description = "Standard ADLS storage account name"
  default     = "lstnsgym"
}

variable "adls_standard_resource_group" {
  type        = string
  description = "Resource group of the Standard ADLS account"
  default     = "lst-consistency"
}

variable "adls_premium_account_name" {
  type        = string
  description = "Premium block-blob ADLS storage account name"
  default     = "lstnsgymx3serug"
}

variable "adls_premium_resource_group" {
  type        = string
  description = "Resource group of the Premium ADLS account"
  default     = "ycsb-catalog-bench-rg"
}
