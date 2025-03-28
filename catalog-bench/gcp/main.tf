provider "google" {
  project = var.gcp_project
  region  = var.gcp_region
}

resource "google_compute_network" "default" {
  name                    = "ycsb-network"
  auto_create_subnetworks = true
}

resource "google_compute_firewall" "ssh" {
  name    = "allow-ssh"
  network = google_compute_network.default.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_instance" "ycsb" {
  name         = "ycsb-instance"
  machine_type = "e2-small"
  zone         = "${var.gcp_region}-b"

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2004-lts"
    }
  }

  network_interface {
    network = google_compute_network.default.name
    access_config {}
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash
    apt-get update
    apt-get install -y docker.io
    systemctl enable docker
    systemctl start docker

    usermod -aG docker ${var.ssh_user}
    mkdir -p /mnt/results

    docker run --rm \
      -e CLOUD=gcp \
      -e GCP_BUCKET=${var.gcs_bucket_name} \
      -v /mnt/results:/YCSB/results \
      ${var.docker_image}

    # shutdown -h now
  EOF

  metadata = {
    ssh-keys = "${var.ssh_user}:${file(var.ssh_public_key_path)}"
  }

  service_account {
    scopes = ["https://www.googleapis.com/auth/devstorage.read_write"]
  }
}

output "instance_ip" {
  value = google_compute_instance.ycsb.network_interface[0].access_config[0].nat_ip
}
