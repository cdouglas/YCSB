# GCP infra: service account, IAM, Standard bucket (created), Rapid bucket
# (adopted via terraform import).
#
# After cloning, adopt the existing Rapid bucket once:
#   terraform -chdir=gcp/infra import google_storage_bucket.rapid lstx-consistency
# Then `terraform plan` must show zero diff for that resource before any apply.

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.40"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.30"
    }
  }
}

provider "google" {
  project = var.gcp_project
  region  = var.gcp_region
  zone    = var.gcp_zone
}

provider "google-beta" {
  project = var.gcp_project
  region  = var.gcp_region
  zone    = var.gcp_zone
}

# Service account used by the benchmark VM.
resource "google_service_account" "benchmark_sa" {
  account_id   = "ycsb-benchmark-sa"
  display_name = "YCSB Benchmark Service Account"
}

resource "google_project_iam_binding" "storage_binding" {
  project = var.gcp_project
  role    = "roles/storage.objectAdmin"

  members = [
    "serviceAccount:${google_service_account.benchmark_sa.email}",
  ]
}

# Standard-class GCS bucket in us-west4 (multi-region not required; same region
# as the VM keeps RTT clean against the Rapid Zonal bucket).
resource "google_storage_bucket" "standard" {
  name                        = var.gcp_standard_bucket_name
  location                    = var.gcp_region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  force_destroy               = true
}

# Rapid Zonal bucket — exists out-of-band from the appendable-objects PoC.
# Adopt via:
#   terraform import google_storage_bucket.rapid <var.gcp_rapid_bucket_name>
resource "google_storage_bucket" "rapid" {
  provider                    = google-beta
  name                        = var.gcp_rapid_bucket_name
  location                    = var.gcp_zone     # zonal placement, required for RAPID
  storage_class               = "RAPID"
  uniform_bucket_level_access = true
  force_destroy               = true

  hierarchical_namespace {
    enabled = true
  }
}

output "service_account_email" {
  value = google_service_account.benchmark_sa.email
}

output "standard_bucket_name" {
  value = google_storage_bucket.standard.name
}

output "rapid_bucket_name" {
  value = google_storage_bucket.rapid.name
}
