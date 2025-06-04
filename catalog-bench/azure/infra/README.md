# HOWTO

1. Log in with `az login`
1. `az account show` (confirm active subscription)
1. Then:

```
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
export ARM_CLIENT_ID=""
export ARM_CLIENT_SECRET=""
export ARM_TENANT_ID=""
```

Terraform script creates premium storage account + 12 SAS accounts
