variable "gcp_project" {
  type    = string
  default = "lst-consistency"
}

variable "gcp_region" {
  type    = string
  default = "us-west4"
}

variable "gcp_zone" {
  type    = string
  default = "us-west4-c"
}

variable "gcp_instance_type" {
  type    = string
  default = "n2-standard-16"
}

variable "ssh_user" {
  type    = string
  default = "gcpuser"
}

variable "ssh_public_key_path" {
  type = string
}
