provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

# IAM Role for EC2 Instance
resource "aws_iam_role" "ec2_role" {
  name = "ycsb-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "ec2.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })
}

# IAM Policy allowing S3 access
resource "aws_iam_policy" "s3_policy" {
  name        = "ycsb-s3-policy"
  description = "Policy for S3 access from EC2"
  policy      = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Action = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket"
      ],
      Resource = [
        "arn:aws:s3:::${var.s3_bucket_name}",
        "arn:aws:s3:::${var.s3_bucket_name}/*"
      ]
    }]
  })
}

# Attach Policy to Role
resource "aws_iam_role_policy_attachment" "s3_policy_attachment" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.s3_policy.arn
}

# Create IAM instance profile
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ycsb-instance-profile"
  role = aws_iam_role.ec2_role.name
}

# Security Group to allow SSH
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

# EC2 Instance
resource "aws_instance" "ycsb" {
  ami                    = "ami-04f5a6a7ecc99fbe2" # Update as needed
  instance_type          = "t3.micro"
  vpc_security_group_ids = [aws_security_group.ycsb.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

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
