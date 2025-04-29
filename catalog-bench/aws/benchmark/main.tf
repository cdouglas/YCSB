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

data "aws_subnet" "selected" {
  id = var.subnet_id
}

resource "aws_security_group" "ycsb_sg" {
  name        = "ycsb-benchmark-sg"
  description = "Allow SSH access for benchmark EC2"
  vpc_id      = data.aws_subnet.selected.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ingress_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "ycsb_vm" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  iam_instance_profile        = data.aws_iam_instance_profile.ycsb_profile.name
  subnet_id                   = var.subnet_id
  associate_public_ip_address = true
  key_name                    = var.ssh_key_name
  vpc_security_group_ids      = [aws_security_group.ycsb_sg.id]

  tags = {
    Name = "ycsb-benchmark"
  }

  provisioner "remote-exec" {
    inline = ["echo Hello from YCSB VM!"]
    connection {
      type        = "ssh"
      user        = "ubuntu"
      host        = self.public_ip
      agent       = true
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

    # Give the user passwordless sudo access
    echo "${var.ssh_user} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${var.ssh_user}
    chmod 440 /etc/sudoers.d/${var.ssh_user}

    # Install Docker
    amazon-linux-extras install docker -y || apt-get update && apt-get install -y docker.io
    systemctl enable docker
    systemctl start docker

    usermod -aG docker ${var.ssh_user}
    mkdir -p /mnt/results

    # EC2 creds into the container (TODO why was this unnecessary before?)
    yum install -y jq
    ROLE=$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/)
    export AWS_ACCESS_KEY_ID=$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE | jq -r .AccessKeyId)
    export AWS_SECRET_ACCESS_KEY=$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE | jq -r .SecretAccessKey)
    export AWS_SESSION_TOKEN=$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE | jq -r .Token)

    # Run benchmark container with volume mount
    docker run --rm \
      -e CLOUD=aws \
      -e S3_BUCKET=${var.s3_bucket_name} \
      -e AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
      -e AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
      -e AWS_SESSION_TOKEN=$AWS_SESSION_TOKEN \
      -v /mnt/results:/YCSB/results \
      ${var.docker_image}
  EOF

}

output "vm_ip" {
  value = aws_instance.ycsb_vm.public_ip
}
