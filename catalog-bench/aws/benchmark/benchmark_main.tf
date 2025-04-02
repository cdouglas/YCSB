
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
}

output "vm_public_ip" {
  value = aws_instance.ycsb_vm.public_ip
}
