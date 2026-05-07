# GCP benchmark VM: single n2-standard-16 in us-west4-c, hits both the Standard
# (lst-uw4-std) and Rapid (lstx-consistency) buckets.  No docker; the YCSB tree
# is rsync'd onto the VM by `bench.sh setup gcp` and built locally with mvn.

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.40"
    }
  }
}

provider "google" {
  project = var.gcp_project
  region  = var.gcp_region
  zone    = var.gcp_zone
}

# Read service account email from the infra module's state.  Falls back to a
# direct lookup if remote state is not configured (it isn't here).
data "google_service_account" "benchmark_sa" {
  account_id = "ycsb-benchmark-sa"
}

resource "google_compute_network" "benchmark_network" {
  name                    = "ycsb-benchmark-network"
  auto_create_subnetworks = true
}

resource "google_compute_firewall" "ssh" {
  name    = "ycsb-benchmark-ssh"
  network = google_compute_network.benchmark_network.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["ycsb-benchmark"]
}

resource "google_compute_instance" "benchmark" {
  name         = "ycsb-benchmark"
  machine_type = var.gcp_instance_type
  zone         = var.gcp_zone
  tags         = ["ycsb-benchmark"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 50
    }
  }

  network_interface {
    network = google_compute_network.benchmark_network.name
    access_config {}
  }

  service_account {
    email  = data.google_service_account.benchmark_sa.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    ssh-keys = "${var.ssh_user}:${file(var.ssh_public_key_path)}"
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash
    set -eux
    export TZ=Etc/UTC DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl git jq \
      maven openjdk-17-jdk-headless rsync ssh unzip wget
    mkdir -p /mnt/results /YCSB
    chown ${var.ssh_user}:${var.ssh_user} /mnt/results /YCSB
  EOF
}

output "vm_ip" {
  value = google_compute_instance.benchmark.network_interface[0].access_config[0].nat_ip
}
