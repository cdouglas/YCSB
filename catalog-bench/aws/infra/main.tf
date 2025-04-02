
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

# Create S3 Express One Zone bucket
resource "aws_s3_bucket" "benchmark" {
  bucket = var.s3_bucket_name

  bucket_prefix         = null
  force_destroy         = true

  object_lock_enabled = false
  tags = {
    Name        = "ycsb-benchmark"
    Environment = "benchmark"
  }
}

resource "aws_s3_bucket_ownership_controls" "ownership" {
  bucket = aws_s3_bucket.benchmark.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Create IAM Role for EC2
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

# IAM Policy for EC2 access to S3
resource "aws_iam_policy" "s3_policy" {
  name        = "ycsb-s3-policy"
  description = "Policy allowing EC2 access to S3 for YCSB benchmark"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:DeleteObject",
          "s3:PutObjectTagging"
        ],
        Resource = [
          "arn:aws:s3:::${var.s3_bucket_name}",
          "arn:aws:s3:::${var.s3_bucket_name}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_policy" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.s3_policy.arn
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ycsb-ec2-instance-profile"
  role = aws_iam_role.ec2_role.name
}

output "s3_bucket_name" {
  value = aws_s3_bucket.benchmark.id
}

output "iam_instance_profile_name" {
  value = aws_iam_instance_profile.ec2_profile.name
}
