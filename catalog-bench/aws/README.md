# AWS catalog-bench setup

Notes specific to driving the AWS sweep with `bench.sh`.  Generic
configuration lives in [`../README.md`](../README.md); this file covers
**only** the AWS-specific bootstrapping that bit us in the May 2026
refresh.

## IAM principal: what `casuser` (or your equivalent) needs

`bench.sh init aws --apply` runs `terraform plan` and `terraform apply`
from the workstation against `aws/infra/`.  The plan does a state
refresh that touches every resource the module manages, including the
existing IAM role / policy / instance profile and the imported S3
Express bucket.  A least-privileged user (e.g. `casuser`) typically
cannot do those reads, and the apply also writes the IAM policy.

The minimum permissions required for a clean
`bench.sh init aws --apply`:

**Reads (terraform refresh):**

- `iam:GetRole`, `iam:GetRolePolicy`, `iam:ListRolePolicies`,
  `iam:ListAttachedRolePolicies` on `role/ycsb-ec2-role`
- `iam:GetInstanceProfile`, `iam:ListInstanceProfilesForRole` on
  `instance-profile/ycsb-ec2-profile`
- `iam:GetPolicy`, `iam:GetPolicyVersion`, `iam:ListPolicyVersions` on
  `policy/ycsb-s3-policy`
- `s3express:GetBucketPolicy`, `s3express:ListTagsForResource`,
  `s3express:GetBucketTagging` on
  `bucket/lst-pbafvfgrapl--usw2-az3--x-s3`
- A handful of `s3:Get*` reads on the Standard bucket
  `lst-pbafvfgrapl` (tagging, policy, ACL, CORS, etc. — terraform-AWS
  provider refreshes all of them)

**Writes (terraform apply):**

- `iam:CreatePolicyVersion`, `iam:DeletePolicyVersion`,
  `iam:SetDefaultPolicyVersion` on `policy/ycsb-s3-policy` (needed when
  the IAM policy doc changes — e.g., adding the Express bucket ARN to
  the resource list)

These are **in addition to** whatever permissions the principal already
has for actually running the benchmark (`s3:*` on the data buckets,
typically already attached via the existing `ycsb-s3-policy` once the
EC2 instance assumes its role; this is unrelated).

### Recipe (admin/root attaches once)

Two policies attached to the principal — one read, one write — so the
read perms can be reused for `bench.sh status aws` etc. without
granting unnecessary IAM write.

`/tmp/ycsb-tf-readperms.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "IAMReadForTerraformRefresh",
      "Effect": "Allow",
      "Action": [
        "iam:GetRole",
        "iam:GetRolePolicy",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies",
        "iam:GetInstanceProfile",
        "iam:ListInstanceProfilesForRole",
        "iam:GetPolicy",
        "iam:GetPolicyVersion",
        "iam:ListPolicyVersions"
      ],
      "Resource": [
        "arn:aws:iam::<ACCOUNT>:role/ycsb-ec2-role",
        "arn:aws:iam::<ACCOUNT>:instance-profile/ycsb-ec2-profile",
        "arn:aws:iam::<ACCOUNT>:policy/ycsb-s3-policy"
      ]
    },
    {
      "Sid": "S3ExpressReadForTerraformRefresh",
      "Effect": "Allow",
      "Action": [
        "s3express:GetBucketPolicy",
        "s3express:ListTagsForResource",
        "s3express:GetBucketTagging"
      ],
      "Resource": [
        "arn:aws:s3express:<REGION>:<ACCOUNT>:bucket/<EXPRESS_BUCKET>"
      ]
    },
    {
      "Sid": "S3StandardReadForTerraformRefresh",
      "Effect": "Allow",
      "Action": [
        "s3:GetBucketTagging",
        "s3:GetBucketPolicy",
        "s3:GetBucketAcl",
        "s3:GetBucketCors",
        "s3:GetBucketWebsite",
        "s3:GetBucketLogging",
        "s3:GetBucketVersioning",
        "s3:GetReplicationConfiguration",
        "s3:GetBucketRequestPayment",
        "s3:GetBucketLocation",
        "s3:GetBucketObjectLockConfiguration"
      ],
      "Resource": [
        "arn:aws:s3:::<STANDARD_BUCKET>",
        "arn:aws:s3:::<EXPRESS_BUCKET>"
      ]
    }
  ]
}
```

`/tmp/ycsb-tf-iamwrite.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "IAMWriteForPolicyUpdates",
    "Effect": "Allow",
    "Action": [
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion"
    ],
    "Resource": "arn:aws:iam::<ACCOUNT>:policy/ycsb-s3-policy"
  }]
}
```

Run as an AWS admin (root, or any principal with `iam:CreatePolicy` +
`iam:AttachUserPolicy`):

```bash
ACCOUNT=762233762747          # adjust
USER=casuser                  # adjust

aws iam create-policy --policy-name ycsb-tf-readperms \
  --policy-document file:///tmp/ycsb-tf-readperms.json
aws iam create-policy --policy-name ycsb-tf-iamwrite \
  --policy-document file:///tmp/ycsb-tf-iamwrite.json
aws iam attach-user-policy --user-name $USER \
  --policy-arn arn:aws:iam::$ACCOUNT:policy/ycsb-tf-readperms
aws iam attach-user-policy --user-name $USER \
  --policy-arn arn:aws:iam::$ACCOUNT:policy/ycsb-tf-iamwrite
```

If the principal already has an admin / power-user policy attached,
none of the above is needed.

### Verifying the perms

```bash
# Sanity check from the workstation as the under-privileged user:
terraform -chdir=catalog-bench/aws/infra plan -input=false
```

A clean run prints `Plan: ...` with no `Error:` lines from
`reading inline policies` / `listing tags`.  After that,
`bench.sh init aws --apply` will succeed end-to-end.

## Other AWS-specific bootstrapping

- **S3 Express bucket adoption**: the existing
  `lst-pbafvfgrapl--usw2-az3--x-s3` directory bucket is brought into
  terraform state via `terraform import`.  `bench.sh init aws` runs
  this automatically (only on the first call, when the resource isn't
  in state).  See `bin/bench.sh` `cmd_init`.
- **AMI**: pinned to a specific Ubuntu 22.04 LTS AMI in
  `benchmark/terraform.tfvars`.  Update if it gets deprecated; check
  for a current `ubuntu-jammy-22.04-amd64-server-*` in your region.
- **SSH key**: defaults to `~/.ssh/id_ed25519`; the EC2 key pair name
  is `bearyak`.  Override via `bench.env` (`AWS_SSH_PRIVATE_KEY`) and
  `benchmark/terraform.tfvars` (`ssh_key_name`).
