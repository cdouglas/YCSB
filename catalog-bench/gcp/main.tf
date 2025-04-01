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
  machine_type = "e2-standard-4"  # More powerful machine for benchmarking
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
    apt-get update
    apt-get install -y docker.io git
    systemctl enable docker
    systemctl start docker
    
    # Create results directory with proper permissions
    mkdir -p /opt/benchmark/results
    chmod 777 /opt/benchmark/results
    
    # Run the benchmark with explicit GCP configuration
    docker run --rm \
      -e CLOUD=gcp \
      -e GCP_BUCKET="${var.gcp_bucket_name}" \
      -e THREAD_RANGE="1..8" \
      -e RUNS="5" \
      -v /opt/benchmark/results:/YCSB/results \
      --name benchmark-container \
      ${var.docker_image}
      
    # Save logs for debugging
    docker logs benchmark-container > /opt/benchmark/docker_logs.txt 2>&1 || true
  EOF
}

output "instance_ip" {
  value = google_compute_instance.benchmark_instance.network_interface[0].access_config[0].nat_ip
}

output "bucket_name" {
  value = data.google_storage_bucket.existing_bucket.name
}
