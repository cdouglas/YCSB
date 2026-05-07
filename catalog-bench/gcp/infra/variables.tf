variable "gcp_project" {
  type    = string
  default = "lst-consistency"
}

variable "gcp_region" {
  type        = string
  description = "Region for the Standard bucket and (Rapid bucket's) provider config"
  default     = "us-west4"
}

variable "gcp_zone" {
  type        = string
  description = "Zonal placement of the Rapid bucket (and the benchmark VM)"
  default     = "us-west4-c"
}

variable "gcp_standard_bucket_name" {
  type        = string
  description = "Standard-class GCS bucket created in this module"
  default     = "lst-uw4-std"
}

variable "gcp_rapid_bucket_name" {
  type        = string
  description = "Existing Rapid Zonal bucket adopted via terraform import"
  default     = "lstx-consistency"
}
