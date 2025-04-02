#!/bin/bash
set -euo pipefail

SSH_CONFIG_PATH="ycsb-vm.conf"

# echo "🔧 Writing SSH config for ycsb-vm to $SSH_CONFIG_PATH..."
terraform output -raw ssh_config | tee  "$SSH_CONFIG_PATH"
# echo "✅ SSH config ready."
ssh -F $SSH_CONFIG_PATH ycsb-vm
