#!/usr/bin/env bash
# =============================================================================
# upload-vhd.sh
#
# Download the F5 XC CE VHD image and upload it to Azure Gov Storage as a
# Page Blob. Accepts either a download URL (from F5 XC Console "Copy Image
# Name") or a local tar/gz file.
#
# Usage:
#   # From URL (recommended):
#   ./scripts/upload-vhd.sh \
#     --url "https://vesio.blob.core.windows.net/releases/rhel/9/x86_64/images/securemeshV2/azure/f5xc-ce-9.2024.44-20250102054713.vhd.gz" \
#     --storage-account mystorageacct \
#     --resource-group my-rg
#
#   # From local file:
#   ./scripts/upload-vhd.sh \
#     --file /path/to/f5xc-ce.vhd.tar \
#     --storage-account mystorageacct \
#     --resource-group my-rg
# =============================================================================
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Source (one required):
  --url URL               F5 XC CE image download URL (from Console "Copy Image Name")
  --file PATH             Local tar or vhd.gz file

Azure Storage (required):
  --storage-account NAME  Azure Gov Storage account name
  --resource-group NAME   Resource group containing the storage account

Optional:
  --container NAME        Blob container name (default: f5xc-ce-images)
  --help                  Show this help
EOF
  exit 1
}

URL=""
FILE=""
STORAGE_ACCOUNT=""
CONTAINER="f5xc-ce-images"
RESOURCE_GROUP=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --url)              URL="$2";              shift 2 ;;
    --file)             FILE="$2";             shift 2 ;;
    --storage-account)  STORAGE_ACCOUNT="$2";  shift 2 ;;
    --container)        CONTAINER="$2";        shift 2 ;;
    --resource-group)   RESOURCE_GROUP="$2";   shift 2 ;;
    --help)             usage ;;
    *)                  echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$STORAGE_ACCOUNT" || -z "$RESOURCE_GROUP" ]] && { echo "ERROR: --storage-account and --resource-group are required"; usage; }
[[ -z "$URL" && -z "$FILE" ]] && { echo "ERROR: provide --url or --file"; usage; }

# Ensure Azure Gov
CLOUD_NAME=$(az cloud show --query name -o tsv 2>/dev/null || echo "")
if [[ "$CLOUD_NAME" != "AzureUSGovernment" ]]; then
  echo "ERROR: Azure CLI must target AzureUSGovernment. Run: az cloud set --name AzureUSGovernment && az login"
  exit 1
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# ---- Get the VHD file ----
if [[ -n "$URL" ]]; then
  FILENAME=$(basename "$URL")
  echo "==> Downloading: $FILENAME"
  curl -fL --progress-bar -o "$WORK_DIR/$FILENAME" "$URL"
  FILE="$WORK_DIR/$FILENAME"
elif [[ ! -f "$FILE" ]]; then
  echo "ERROR: File not found: $FILE"
  exit 1
fi

# ---- Extract if compressed ----
VHD_FILE=""
case "$FILE" in
  *.tar)
    echo "==> Extracting tar archive..."
    tar -xf "$FILE" -C "$WORK_DIR"
    ;;
  *.vhd.gz|*.gz)
    echo "==> Decompressing gzip..."
    cp "$FILE" "$WORK_DIR/"
    gunzip "$WORK_DIR/$(basename "$FILE")"
    ;;
  *.vhd)
    VHD_FILE="$FILE"
    ;;
  *)
    echo "ERROR: Unsupported file type: $FILE"
    exit 1
    ;;
esac

# Find the VHD if not already set
if [[ -z "$VHD_FILE" ]]; then
  # Look for .vhd, also handle nested .vhd.gz from tar
  GZ_FILE=$(find "$WORK_DIR" -name "*.vhd.gz" -type f 2>/dev/null | head -1)
  [[ -n "$GZ_FILE" ]] && gunzip "$GZ_FILE"
  VHD_FILE=$(find "$WORK_DIR" -name "*.vhd" -type f | head -1)
fi

if [[ -z "$VHD_FILE" ]]; then
  echo "ERROR: No .vhd file found after extraction"
  exit 1
fi

BLOB_NAME=$(basename "$VHD_FILE")
VHD_SIZE=$(stat -c%s "$VHD_FILE" 2>/dev/null || stat -f%z "$VHD_FILE")
echo "==> VHD: $BLOB_NAME ($(numfmt --to=iec-i --suffix=B "$VHD_SIZE" 2>/dev/null || echo "${VHD_SIZE} bytes"))"

# ---- Retrieve storage account key ----
echo "==> Retrieving storage account key..."
ACCOUNT_KEY=$(az storage account keys list \
  --account-name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --query '[0].value' -o tsv)

# ---- Create container if needed ----
echo "==> Ensuring container '$CONTAINER' exists..."
az storage container create \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$ACCOUNT_KEY" \
  --name "$CONTAINER" \
  --output none 2>/dev/null || true

# ---- Check if blob already exists ----
EXISTS=$(az storage blob exists \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$ACCOUNT_KEY" \
  --container-name "$CONTAINER" \
  --name "$BLOB_NAME" \
  --query exists -o tsv 2>/dev/null || echo "false")

if [[ "$EXISTS" == "true" ]]; then
  echo "==> Blob '$BLOB_NAME' already exists in container. Skipping upload."
else
  echo "==> Uploading as Page Blob to Azure Gov storage..."
  echo "    Account:   $STORAGE_ACCOUNT"
  echo "    Container: $CONTAINER"
  echo "    Blob:      $BLOB_NAME"
  az storage blob upload \
    --account-name "$STORAGE_ACCOUNT" \
    --account-key "$ACCOUNT_KEY" \
    --container-name "$CONTAINER" \
    --name "$BLOB_NAME" \
    --file "$VHD_FILE" \
    --type page \
    --overwrite
fi

echo ""
echo "==> Done! Use these in terraform.tfvars:"
echo ""
echo "  vhd_storage_account_name   = \"$STORAGE_ACCOUNT\""
echo "  vhd_storage_container_name = \"$CONTAINER\""
echo "  vhd_blob_name              = \"$BLOB_NAME\""
