# AWS access
aws_profile="default"
aws_region="us-west-2"

# from infra
s3_bucket_name="lst-pbafvfgrapl"
iam_instance_profile_name="ycsb-ec2-instance-profile"

# EC2 instance
# instance_type="t3.medium"
instance_type="m5.2xlarge"
# ami_id="ami-08c40ec9ead489470" # Ubuntu 20.04 for us-west-2 (update if needed)
ami_id = "ami-0c1ade727754a7a75"  # Jammy 22.04 LTS, amd64, hvm:ebs-ssd
subnet_id="subnet-0768f86d4a1318aab"
ssh_key_name="bearyak"
ssh_private_key_path="~/.ssh/id_ed25519"
ssh_user="awsuser"
ssh_public_key_path="~/.ssh/id_ed25519.pub"

# Docker image
docker_image="cdouglas/catalog-bench:latest"
