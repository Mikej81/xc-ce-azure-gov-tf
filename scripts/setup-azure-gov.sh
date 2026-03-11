#!/usr/bin/env bash
# =============================================================================
# setup-azure-gov.sh
#
# Log in to Azure Government, create a Service Principal with Contributor role,
# and export the environment variables Terraform needs.
#
# Usage:
#   source ./scripts/setup-azure-gov.sh            # interactive login
#   source ./scripts/setup-azure-gov.sh --spn-name my-spn  # custom SPN name
#
# After running, Terraform's azurerm provider will authenticate via:
#   ARM_CLIENT_ID, ARM_CLIENT_SECRET, ARM_TENANT_ID,
#   ARM_SUBSCRIPTION_ID, ARM_ENVIRONMENT
# =============================================================================
set -euo pipefail

SPN_NAME="http://f5xc-ce-terraform"

while [[ $# -gt 0 ]]; do
  case $1 in
    --spn-name) SPN_NAME="$2"; shift 2 ;;
    *)          echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ---- Switch to Azure Government cloud ----
CURRENT_CLOUD=$(az cloud show --query name -o tsv 2>/dev/null || echo "")
if [[ "$CURRENT_CLOUD" != "AzureUSGovernment" ]]; then
  echo "==> Switching Azure CLI to AzureUSGovernment..."
  az cloud set --name AzureUSGovernment
fi

# ---- Log in ----
echo "==> Logging in to Azure Government..."
az login

# ---- Show and confirm subscription ----
echo ""
echo "==> Current subscription:"
az account show --output table
echo ""
read -rp "Use this subscription? [Y/n] " confirm
if [[ "${confirm,,}" == "n" ]]; then
  echo ""
  az account list --output table
  echo ""
  read -rp "Enter subscription name or ID: " sub
  az account set --subscription "$sub"
fi

# ---- Export subscription and tenant ----
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
export ARM_TENANT_ID=$(az account show --query tenantId -o tsv)
export ARM_ENVIRONMENT="usgovernment"

# ---- Create SPN ----
echo ""
echo "==> Creating Service Principal: $SPN_NAME"
SPN_OUTPUT=$(az ad sp create-for-rbac \
  --role "Contributor" \
  --scopes "/subscriptions/$ARM_SUBSCRIPTION_ID" \
  --name "$SPN_NAME" \
  --output json)

export ARM_CLIENT_ID=$(echo "$SPN_OUTPUT" | jq -r '.appId')
export ARM_CLIENT_SECRET=$(echo "$SPN_OUTPUT" | jq -r '.password')

# ---- Also set TF_VAR equivalents ----
export TF_VAR_azure_subscription_id="$ARM_SUBSCRIPTION_ID"
export TF_VAR_azure_tenant_id="$ARM_TENANT_ID"
export TF_VAR_azure_client_id="$ARM_CLIENT_ID"
export TF_VAR_azure_client_secret="$ARM_CLIENT_SECRET"

echo ""
echo "==> Azure Gov environment variables set:"
echo "    ARM_ENVIRONMENT       = $ARM_ENVIRONMENT"
echo "    ARM_SUBSCRIPTION_ID   = $ARM_SUBSCRIPTION_ID"
echo "    ARM_TENANT_ID         = $ARM_TENANT_ID"
echo "    ARM_CLIENT_ID         = $ARM_CLIENT_ID"
echo "    ARM_CLIENT_SECRET     = (set)"
echo ""
echo "==> Volterra P12 password (set this if not already):"
echo "    export VES_P12_PASSWORD=<your-p12-password>"
echo ""
echo "Ready for: terraform init && terraform plan"
