provider "google" {
  project = var.gcp_project
  region  = var.gcp_region
  zone    = var.gcp_zone
}

# Use existing bucket instead of creating a new one
data "google_storage_bucket" "existing_bucket" {
  name = var.gcp_bucket_name
}

# Service account for the VM
resource "google_service_account" "benchmark_sa" {
  account_id   = "ycsb-benchmark-sa"
  display_name = "YCSB Benchmark Service Account"
}

# Grant storage object admin permissions
resource "google_project_iam_binding" "storage_binding" {
  project = var.gcp_project
  role    = "roles/storage.objectAdmin"

  members = [
    "serviceAccount:${google_service_account.benchmark_sa.email}"
  ]
}

# Create a new VPC network for the benchmark
resource "google_compute_network" "benchmark_network" {
  name = "benchmark-network"
  auto_create_subnetworks = true
}

# Firewall rule to allow SSH
resource "google_compute_firewall" "benchmark_firewall" {
  name    = "benchmark-firewall"
  network = google_compute_network.benchmark_network.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["benchmark"]
}

# GCP VM Instance
resource "google_compute_instance" "benchmark_instance" {
  name         = "ycsb-benchmark-instance"
  machine_type = var.instance_type
  tags         = ["benchmark"]
  zone         = var.gcp_zone     # Make sure this is a valid zone

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2004-lts"
      size  = 50  # Larger disk for benchmark results
    }
  }

  network_interface {
    network = google_compute_network.benchmark_network.name
    access_config {}  # Gives external IP
  }

  service_account {
    email  = google_service_account.benchmark_sa.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    ssh-keys = "${var.ssh_user}:${file(var.ssh_public_key_path)}"
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash

    export TZ=Etc/UTC
    export DEBIAN_FRONTEND=noninteractive
    export CLOUD=gcp
    export GCP_BUCKET=${var.gcp_bucket_name}

    apt-get update
    apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      dbus-user-session \
      git \
      gnupg \
      jq \
      lsb-release \
      openjdk-17-jdk-headless \
      python3-pip \
      software-properties-common \
      ssh \
      unzip \
      wget

  EOF
}

output "vm_ip" {
  value = google_compute_instance.benchmark_instance.network_interface[0].access_config[0].nat_ip
}

output "bucket_name" {
  value = data.google_storage_bucket.existing_bucket.name
}

output "results_path" {
  value = "/mnt/results"
  description = "Path to benchmark results on the VM"
}
