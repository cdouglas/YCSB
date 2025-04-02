#!/bin/bash

set -euo pipefail

cd infra
echo "🚀 Applying Terraform in infra/..."
terraform init -input=false
terraform apply -auto-approve

echo "📦 Capturing outputs..."
BUCKET=$(terraform output -raw s3_bucket_name)
PROFILE=$(terraform output -raw iam_instance_profile_name)

cd ../benchmark
echo "🚀 Applying Terraform in benchmark/..."
terraform init -input=false
terraform apply -auto-approve \
  -var "s3_bucket_name=$BUCKET" \
  -var "iam_instance_profile_name=$PROFILE" \
  -var "aws_region=us-west-2" \
  -var "aws_profile=default" \
  -var "ami_id=ami-1234567890abcdef0" \
  -var "subnet_id=subnet-xxxxxxxx" \
  -var "ssh_key_name=my-key" \
  -var "ssh_private_key_path=$HOME/.ssh/my-key.pem"
