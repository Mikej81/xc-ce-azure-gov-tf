# -----------------------------------------------------------------------------
# CE VHD Image
#
# When vhd_download_url is set, Terraform will automatically download the
# .vhd.gz from the F5 XC image repository, decompress it, and upload it
# to Azure Gov Storage as a Page Blob. Subsequent applies skip the upload
# if the blob already exists.
#
# The download URL comes from the F5 XC Console: create an SMSv2 site,
# then click ... > Copy Image Name.
# -----------------------------------------------------------------------------

locals {
  # Derive blob name from download URL: strip path and .gz extension
  # e.g. "f5xc-ce-9.2024.44-20250102054713.vhd.gz" -> "f5xc-ce-9.2024.44-20250102054713.vhd"
  vhd_blob_name = coalesce(
    var.vhd_blob_name,
    var.vhd_download_url != null ? replace(basename(var.vhd_download_url), ".gz", "") : null,
    "ce-image.vhd"
  )
}

data "azurerm_storage_account" "vhd" {
  count               = var.image_id == null && var.vhd_storage_account_name != null ? 1 : 0
  name                = var.vhd_storage_account_name
  resource_group_name = local.resource_group_name
}

# Download and upload the VHD when a download URL is provided and no image_id is given.
# Skips if the blob already exists in storage.
resource "terraform_data" "vhd_upload" {
  count = var.image_id == null && var.vhd_download_url != null ? 1 : 0

  triggers_replace = [var.vhd_download_url]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-SCRIPT
      set -euo pipefail

      ACCOUNT="${local.storage_account_name}"
      CONTAINER="${var.vhd_storage_container_name}"
      BLOB_NAME="${local.vhd_blob_name}"

      # Retrieve storage account key (Contributor role can list keys)
      ACCOUNT_KEY=$(az storage account keys list \
        --account-name "$ACCOUNT" \
        --resource-group "${local.resource_group_name}" \
        --query '[0].value' -o tsv)

      # Check if blob already exists
      EXISTS=$(az storage blob exists \
        --account-name "$ACCOUNT" \
        --account-key "$ACCOUNT_KEY" \
        --container-name "$CONTAINER" \
        --name "$BLOB_NAME" \
        --query exists -o tsv 2>/dev/null || echo "false")

      if [[ "$EXISTS" == "true" ]]; then
        echo "VHD blob '$BLOB_NAME' already exists. Skipping download and upload."
        exit 0
      fi

      WORK_DIR=$(mktemp -d)
      trap 'rm -rf "$WORK_DIR"' EXIT

      echo "Downloading CE VHD image..."
      curl -fL --progress-bar -o "$WORK_DIR/$(basename "${var.vhd_download_url}")" "${var.vhd_download_url}"

      echo "Decompressing..."
      gunzip "$WORK_DIR/"*.gz

      VHD_FILE=$(find "$WORK_DIR" -name "*.vhd" -type f | head -1)

      # Ensure container exists
      az storage container create \
        --account-name "$ACCOUNT" \
        --account-key "$ACCOUNT_KEY" \
        --name "$CONTAINER" \
        --output none 2>/dev/null || true

      echo "Uploading as Page Blob to Azure Gov storage..."
      az storage blob upload \
        --account-name "$ACCOUNT" \
        --account-key "$ACCOUNT_KEY" \
        --container-name "$CONTAINER" \
        --name "$BLOB_NAME" \
        --file "$VHD_FILE" \
        --type page \
        --overwrite
      echo "Upload complete: $BLOB_NAME"
    SCRIPT
  }
}

locals {
  storage_blob_endpoint = (
    var.image_id != null ? null :
    var.vhd_storage_account_name != null ? data.azurerm_storage_account.vhd[0].primary_blob_endpoint :
    azurerm_storage_account.vhd[0].primary_blob_endpoint
  )

  # Resolve to existing image or the one we create
  ce_image_id = var.image_id != null ? var.image_id : azurerm_image.ce[0].id
}

resource "azurerm_storage_account" "vhd" {
  count                    = var.image_id == null && var.vhd_storage_account_name == null ? 1 : 0
  name                     = replace("${var.site_name}${random_id.suffix.hex}vhd", "-", "")
  resource_group_name      = local.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  tags                     = local.common_tags
}

resource "azurerm_image" "ce" {
  count               = var.image_id == null ? 1 : 0
  name                = "${var.site_name}-ce-image"
  location            = var.location
  resource_group_name = local.resource_group_name

  os_disk {
    os_type      = "Linux"
    os_state     = "Generalized"
    blob_uri     = "${local.storage_blob_endpoint}${var.vhd_storage_container_name}/${local.vhd_blob_name}"
    storage_type = "StandardSSD_LRS"
  }

  tags = merge(var.tags, { Name = "${var.site_name}-ce-image" })

  depends_on = [terraform_data.vhd_upload]
}
