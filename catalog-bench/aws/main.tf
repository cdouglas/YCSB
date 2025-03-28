provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

resource "aws_security_group" "ycsb" {
  name        = "ycsb-sg"
  description = "Allow SSH access"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

// AMI from:
// aws ec2 describe-images
//   --owners 099720109477
//   --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*" "Name=virtualization-type,Values=hvm" "Name=root-device-type,Values=ebs"
//   --query 'Images[*].[ImageId,Name]'
//   --region us-west-2
//   --output table


resource "aws_instance" "ycsb" {
  ami                    = "ami-04f5a6a7ecc99fbe2" # Ubuntu 20.04 for us-west-2 (update if needed)
  instance_type          = "t3.micro"
  vpc_security_group_ids = [aws_security_group.ycsb.id]

  user_data = <<-EOF
    #!/bin/bash
    useradd -m -s /bin/bash ${var.ssh_user}
    mkdir -p /home/${var.ssh_user}/.ssh
    echo "${file(var.ssh_public_key_path)}" > /home/${var.ssh_user}/.ssh/authorized_keys
    chown -R ${var.ssh_user}:${var.ssh_user} /home/${var.ssh_user}/.ssh
    chmod 600 /home/${var.ssh_user}/.ssh/authorized_keys
    apt-get update
    apt-get install -y docker.io
    systemctl enable docker
    systemctl start docker
    usermod -aG docker ${var.ssh_user}
    mkdir -p /mnt/results

    docker run --rm \
      -e CLOUD=aws \
      -e S3_BUCKET=${var.s3_bucket_name} \
      -v /mnt/results:/YCSB/results \
      ${var.docker_image}

    # shutdown -h now
  EOF

  tags = {
    Name = "ycsb-benchmark"
  }
}

output "instance_ip" {
  value = aws_instance.ycsb.public_ip
}
