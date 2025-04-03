
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

data "aws_iam_instance_profile" "ycsb_profile" {
  name = var.iam_instance_profile_name
}

data "aws_s3_bucket" "benchmark_bucket" {
  bucket = var.s3_bucket_name
}

resource "aws_instance" "ycsb_vm" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  iam_instance_profile        = data.aws_iam_instance_profile.ycsb_profile.name
  subnet_id                   = var.subnet_id
  associate_public_ip_address = true
  key_name                    = var.ssh_key_name

  tags = {
    Name = "ycsb-benchmark"
  }

  provisioner "remote-exec" {
    inline = ["echo Hello from YCSB VM!"]
    connection {
      type        = "ssh"
      user        = "ec2-user"
      private_key = file(var.ssh_private_key_path)
      host        = self.public_ip
    }
  }
  user_data = <<-EOF
    #!/bin/bash
    set -eux

    useradd -m -s /bin/bash ${var.ssh_user}
    mkdir -p /home/${var.ssh_user}/.ssh
    echo "${file(var.ssh_public_key_path)}" > /home/${var.ssh_user}/.ssh/authorized_keys
    chown -R ${var.ssh_user}:${var.ssh_user} /home/${var.ssh_user}/.ssh
    chmod 600 /home/${var.ssh_user}/.ssh/authorized_keys

    # Install Docker
    amazon-linux-extras install docker -y
    systemctl enable docker
    systemctl start docker

    usermod -aG docker ${var.ssh_user}
    mkdir -p /mnt/results

    # Run benchmark container with volume mount
    docker run --rm \
      -e CLOUD=aws \
      -e S3_BUCKET=${var.s3_bucket_name} \
      -v /mnt/results:/YCSB/results \
      ${var.docker_image}
  EOF

}

output "vm_public_ip" {
  value = aws_instance.ycsb_vm.public_ip
}
