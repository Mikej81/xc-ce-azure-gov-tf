# -----------------------------------------------------------------------------
# F5 XC API
# -----------------------------------------------------------------------------

variable "f5xc_api_url" {
  type        = string
  description = "F5 XC tenant API URL"
}

variable "f5xc_api_p12_file" {
  type        = string
  description = "Path to the F5 XC API credentials P12 file (password via VES_P12_PASSWORD env var)"
}

variable "f5xc_api_token" {
  type        = string
  description = "F5 XC API token for Day-2 provisioners (set public IP, configure segments). If provided, used instead of P12 for API calls."
  default     = null
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Network Segment (Day-2)
# -----------------------------------------------------------------------------

variable "segment_name" {
  type        = string
  description = "Network segment to assign to the SLI interface after site registration. If null, no segment is configured."
  default     = null
}

# -----------------------------------------------------------------------------
# Azure
# -----------------------------------------------------------------------------

variable "location" {
  type        = string
  description = "Azure Gov region"
  default     = "usgovvirginia"
}

variable "resource_group_name" {
  type        = string
  description = "Existing Azure resource group. If null, a new RG is created."
  default     = null
}

variable "vnet_name" {
  type        = string
  description = "Existing Azure Virtual Network. If null, a new VNet is created."
  default     = null
}

variable "vnet_address_space" {
  type        = string
  description = "Address space for the VNet (only used when creating a new VNet)"
  default     = "10.0.0.0/16"
}

variable "outside_subnet_name" {
  type        = string
  description = "Existing SLO (outside) subnet name. If null, a new subnet is created."
  default     = null
}

variable "outside_subnet_cidr" {
  type        = string
  description = "CIDR for the SLO subnet (only used when creating a new subnet)"
  default     = "10.0.1.0/24"
}

variable "inside_subnet_name" {
  type        = string
  description = "Existing SLI (inside) subnet name. If null, a new subnet is created."
  default     = null
}

variable "inside_subnet_cidr" {
  type        = string
  description = "CIDR for the SLI subnet (only used when creating a new subnet)"
  default     = "10.0.2.0/24"
}

# -----------------------------------------------------------------------------
# VHD Image
#
# Provide vhd_download_url (from F5 XC Console "Copy Image Name") and a
# storage account. Terraform will download, decompress, and upload the VHD
# automatically on first apply.
# -----------------------------------------------------------------------------

variable "image_id" {
  type        = string
  description = "Existing Azure Image ID for the CE. If provided, VHD download/upload is skipped."
  default     = null
}

variable "vhd_download_url" {
  type        = string
  description = "F5 XC CE VHD download URL from Console. Ignored if image_id is provided."
  default     = "https://vesio.blob.core.windows.net/releases/rhel/9/x86_64/images/securemeshV2/azure/f5xc-ce-9.2024.44-20250102054713.vhd.gz"
}

variable "vhd_storage_account_name" {
  type        = string
  description = "Existing Azure Gov Storage account for the CE VHD image. If null, a new one is created."
  default     = null
}

variable "vhd_storage_container_name" {
  type        = string
  description = "Blob container for the CE VHD"
  default     = "f5xc-ce-images"
}

variable "vhd_blob_name" {
  type        = string
  description = "VHD blob name. If vhd_download_url is set, this is derived automatically (filename with .gz stripped)."
  default     = null
}

# -----------------------------------------------------------------------------
# Site
# -----------------------------------------------------------------------------

variable "site_name" {
  type        = string
  description = "F5 XC Secure Mesh Site name (DNS-1035: lowercase, alphanumeric, hyphens)"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*[a-z0-9]$", var.site_name))
    error_message = "Must be DNS-1035 compliant: start with letter, end alphanumeric, lowercase + hyphens only."
  }
}

variable "site_description" {
  type    = string
  default = "F5 XC SMSv2 CE in Azure Government"
}

# -----------------------------------------------------------------------------
# VM
# -----------------------------------------------------------------------------

variable "instance_type" {
  type        = string
  description = "Azure VM size (min 8 vCPU / 32 GB RAM)"
  default     = "Standard_D8s_v4"
}

variable "os_disk_size_gb" {
  type    = number
  default = 128
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key for CE admin access"
  sensitive   = true
}


# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------

variable "enable_site_mesh_group" {
  type        = bool
  description = "Enable site mesh group on SLO for site-to-site connectivity"
  default     = true
}

variable "site_mesh_label_key" {
  type        = string
  description = "Label key used by the core MCN virtual site selector to include this CE in a mesh group"
  default     = "site-mesh"
}

variable "site_mesh_label_value" {
  type        = string
  description = "Label value for mesh group membership (must match the core MCN virtual site selector)"
  default     = "global-network-mesh"
}

variable "enable_etcd_fix" {
  type        = bool
  description = "TEMPORARY: Enable cloud-init workaround for VPM bug that leaves ETCD_IMAGE blank in /etc/default/etcd-member. Disable once the CE image is patched."
  default     = true
}

variable "ce_etcd_image" {
  type        = string
  description = "TEMPORARY: Etcd container image for the etcd-member fix. Only used when enable_etcd_fix = true."
  default     = "200853955439.dkr.ecr.us-gov-west-1.amazonaws.com/etcd@sha256:5e084d6d22ee0a3571e3f755b8946cad297afb05e1f3772dc0fcd1a70ae6c928"
}

variable "slo_security_group_id" {
  type        = string
  description = "Existing NSG ID for the SLO NIC. If null, a new NSG is created with a default outbound-allow rule."
  default     = null
}

variable "sli_security_group_id" {
  type        = string
  description = "Existing NSG ID for the SLI NIC. If null, a new NSG is created with a default inbound-allow rule."
  default     = null
}

variable "slo_private_ip" {
  type        = string
  description = "Static SLO IP (null = DHCP)"
  default     = null
}

variable "sli_private_ip" {
  type        = string
  description = "Static SLI IP (null = DHCP)"
  default     = null
}

variable "create_public_ip" {
  type    = bool
  default = true
}

# -----------------------------------------------------------------------------
# Test VM
# -----------------------------------------------------------------------------

variable "deploy_test_vm" {
  type        = bool
  description = "Deploy an Ubuntu test VM on the SLI subnet for connectivity testing"
  default     = false
}

variable "test_vm_size" {
  type        = string
  description = "Azure VM size for the test VM"
  default     = "Standard_B2s"
}

# -----------------------------------------------------------------------------
# Tags
# -----------------------------------------------------------------------------

variable "tags" {
  type    = map(string)
  default = {}
}
