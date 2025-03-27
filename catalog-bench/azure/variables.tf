variable "azure_region" {
    description = "Azure region"
        default     = "East US"
}

variable "ssh_public_key_path" {
    description = "Path to SSH public key"
        type        = string
}
