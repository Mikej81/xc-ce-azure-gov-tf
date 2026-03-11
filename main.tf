# -----------------------------------------------------------------------------
# Azure Infrastructure — F5 XC SMSv2 CE in Azure Government
# -----------------------------------------------------------------------------

resource "random_id" "suffix" {
  byte_length = 2
}

locals {
  prefix = "${var.site_name}-${random_id.suffix.hex}"
  common_tags = merge(var.tags, {
    source    = "terraform"
    site_name = var.site_name
  })

  # Resolve to existing or created resources
  resource_group_name = var.resource_group_name != null ? var.resource_group_name : azurerm_resource_group.this[0].name
  rg_location         = var.resource_group_name != null ? data.azurerm_resource_group.this[0].location : azurerm_resource_group.this[0].location
  vnet_name           = var.vnet_name != null ? var.vnet_name : azurerm_virtual_network.this[0].name
  outside_subnet_id   = var.outside_subnet_name != null ? data.azurerm_subnet.outside[0].id : azurerm_subnet.outside[0].id
  inside_subnet_id    = var.inside_subnet_name != null ? data.azurerm_subnet.inside[0].id : azurerm_subnet.inside[0].id
  inside_subnet_cidr  = var.inside_subnet_name != null ? data.azurerm_subnet.inside[0].address_prefixes[0] : var.inside_subnet_cidr
  storage_account_name = (
    var.image_id != null ? null :
    var.vhd_storage_account_name != null ? var.vhd_storage_account_name :
    azurerm_storage_account.vhd[0].name
  )

  # Use existing NSGs if provided, otherwise use the ones we create
  slo_nsg_id = var.slo_security_group_id != null ? var.slo_security_group_id : azurerm_network_security_group.slo[0].id
  sli_nsg_id = var.sli_security_group_id != null ? var.sli_security_group_id : azurerm_network_security_group.sli[0].id
}

# -----------------------------------------------------------------------------
# Resource Group — use existing or create new
# -----------------------------------------------------------------------------

data "azurerm_resource_group" "this" {
  count = var.resource_group_name != null ? 1 : 0
  name  = var.resource_group_name
}

resource "azurerm_resource_group" "this" {
  count    = var.resource_group_name == null ? 1 : 0
  name     = "${local.prefix}-rg"
  location = var.location
  tags     = local.common_tags
}

# -----------------------------------------------------------------------------
# Virtual Network — use existing or create new
# -----------------------------------------------------------------------------

data "azurerm_virtual_network" "this" {
  count               = var.vnet_name != null ? 1 : 0
  name                = var.vnet_name
  resource_group_name = local.resource_group_name
}

resource "azurerm_virtual_network" "this" {
  count               = var.vnet_name == null ? 1 : 0
  name                = "${local.prefix}-vnet"
  location            = var.location
  resource_group_name = local.resource_group_name
  address_space       = [var.vnet_address_space]
  tags                = local.common_tags
}

# -----------------------------------------------------------------------------
# Subnets — use existing or create new
# -----------------------------------------------------------------------------

data "azurerm_subnet" "outside" {
  count                = var.outside_subnet_name != null ? 1 : 0
  name                 = var.outside_subnet_name
  virtual_network_name = local.vnet_name
  resource_group_name  = local.resource_group_name
}

data "azurerm_subnet" "inside" {
  count                = var.inside_subnet_name != null ? 1 : 0
  name                 = var.inside_subnet_name
  virtual_network_name = local.vnet_name
  resource_group_name  = local.resource_group_name
}

resource "azurerm_subnet" "outside" {
  count                = var.outside_subnet_name == null ? 1 : 0
  name                 = "${local.prefix}-slo"
  resource_group_name  = local.resource_group_name
  virtual_network_name = local.vnet_name
  address_prefixes     = [var.outside_subnet_cidr]
}

resource "azurerm_subnet" "inside" {
  count                = var.inside_subnet_name == null ? 1 : 0
  name                 = "${local.prefix}-sli"
  resource_group_name  = local.resource_group_name
  virtual_network_name = local.vnet_name
  address_prefixes     = [var.inside_subnet_cidr]
}

# -----------------------------------------------------------------------------
# Network Security Groups
# -----------------------------------------------------------------------------

# NSGs — only created when existing NSG IDs are not provided.
# In enterprise environments, pass slo_security_group_id / sli_security_group_id
# to use centrally managed NSGs instead.

resource "azurerm_network_security_group" "slo" {
  count               = var.slo_security_group_id == null ? 1 : 0
  name                = "${local.prefix}-nsg-slo"
  location            = var.location
  resource_group_name = local.resource_group_name
  tags                = local.common_tags
}

resource "azurerm_network_security_group" "sli" {
  count               = var.sli_security_group_id == null ? 1 : 0
  name                = "${local.prefix}-nsg-sli"
  location            = var.location
  resource_group_name = local.resource_group_name
  tags                = local.common_tags
}

resource "azurerm_network_security_rule" "slo_outbound" {
  count                       = var.slo_security_group_id == null ? 1 : 0
  name                        = "AllowAllOutbound"
  priority                    = 100
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.slo[0].name
}

# CE-to-CE IPsec ingress rules for site mesh group connectivity
# Ref: https://docs.cloud.f5.com/docs-v2/multi-cloud-network-connect/reference/ce-ip-dom-ref

resource "azurerm_network_security_rule" "slo_ipsec_ike" {
  count                       = var.slo_security_group_id == null && var.enable_site_mesh_group ? 1 : 0
  name                        = "AllowIPsecIKE"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Udp"
  source_port_range           = "*"
  destination_port_range      = "500"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.slo[0].name
}

resource "azurerm_network_security_rule" "slo_ipsec_natt" {
  count                       = var.slo_security_group_id == null && var.enable_site_mesh_group ? 1 : 0
  name                        = "AllowIPsecNATT"
  priority                    = 111
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Udp"
  source_port_range           = "*"
  destination_port_range      = "4500"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.slo[0].name
}

resource "azurerm_network_security_rule" "slo_ipsec_esp" {
  count                       = var.slo_security_group_id == null && var.enable_site_mesh_group ? 1 : 0
  name                        = "AllowIPsecESP"
  priority                    = 112
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Esp"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.slo[0].name
}

resource "azurerm_network_security_rule" "sli_allow_all" {
  count                       = var.sli_security_group_id == null ? 1 : 0
  name                        = "AllowAllInbound"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.sli[0].name
}

resource "azurerm_network_security_rule" "sli_allow_icmp_outbound" {
  count                       = var.sli_security_group_id == null ? 1 : 0
  name                        = "AllowICMPOutbound"
  priority                    = 110
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Icmp"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = local.inside_subnet_cidr
  destination_address_prefix  = "*"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.sli[0].name
}

# -----------------------------------------------------------------------------
# Public IP (optional)
# -----------------------------------------------------------------------------

resource "azurerm_public_ip" "slo" {
  count               = var.create_public_ip ? 1 : 0
  name                = "${local.prefix}-pip-slo"
  location            = var.location
  resource_group_name = local.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
}

# -----------------------------------------------------------------------------
# NICs — SLO (eth0) then SLI (eth1)
# -----------------------------------------------------------------------------

resource "azurerm_network_interface" "slo" {
  name                           = "${local.prefix}-nic-slo"
  location                       = var.location
  resource_group_name            = local.resource_group_name
  ip_forwarding_enabled          = true
  accelerated_networking_enabled = true

  ip_configuration {
    name                          = "slo"
    subnet_id                     = local.outside_subnet_id
    private_ip_address_allocation = var.slo_private_ip != null ? "Static" : "Dynamic"
    private_ip_address            = var.slo_private_ip
    public_ip_address_id          = var.create_public_ip ? azurerm_public_ip.slo[0].id : null
  }

  tags = local.common_tags
}

resource "azurerm_network_interface_security_group_association" "slo" {
  network_interface_id      = azurerm_network_interface.slo.id
  network_security_group_id = local.slo_nsg_id
}

resource "azurerm_network_interface" "sli" {
  name                           = "${local.prefix}-nic-sli"
  location                       = var.location
  resource_group_name            = local.resource_group_name
  ip_forwarding_enabled          = true
  accelerated_networking_enabled = true

  ip_configuration {
    name                          = "sli"
    subnet_id                     = local.inside_subnet_id
    private_ip_address_allocation = var.sli_private_ip != null ? "Static" : "Dynamic"
    private_ip_address            = var.sli_private_ip
  }

  tags = local.common_tags
}

resource "azurerm_network_interface_security_group_association" "sli" {
  network_interface_id      = azurerm_network_interface.sli.id
  network_security_group_id = local.sli_nsg_id
}

# -----------------------------------------------------------------------------
# CE Virtual Machine
# -----------------------------------------------------------------------------

resource "azurerm_linux_virtual_machine" "ce" {
  name                = local.prefix
  location            = var.location
  resource_group_name = local.resource_group_name
  size                = var.instance_type

  network_interface_ids = [
    azurerm_network_interface.slo.id,
    azurerm_network_interface.sli.id,
  ]

  admin_username                  = "cloud-user"
  disable_password_authentication = true

  admin_ssh_key {
    username   = "cloud-user"
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_id = local.ce_image_id
  custom_data     = base64encode(local.ce_user_data)

  boot_diagnostics {}

  tags = local.common_tags

  depends_on = [
    azurerm_network_interface_security_group_association.slo,
    azurerm_network_interface_security_group_association.sli,
  ]
}

# -----------------------------------------------------------------------------
# Test VM — Ubuntu on SLI subnet (optional, for connectivity testing)
# -----------------------------------------------------------------------------

resource "azurerm_network_interface" "test_vm" {
  count                          = var.deploy_test_vm ? 1 : 0
  name                           = "${local.prefix}-nic-testvm"
  location                       = var.location
  resource_group_name            = local.resource_group_name
  accelerated_networking_enabled = false

  ip_configuration {
    name                          = "sli"
    subnet_id                     = local.inside_subnet_id
    private_ip_address_allocation = "Dynamic"
  }

  tags = local.common_tags
}

resource "azurerm_network_interface_security_group_association" "test_vm" {
  count                     = var.deploy_test_vm ? 1 : 0
  network_interface_id      = azurerm_network_interface.test_vm[0].id
  network_security_group_id = local.sli_nsg_id
}

locals {
  test_vm_custom_data = <<-CLOUDINIT
    #cloud-config
    write_files:
      - path: /etc/netplan/99-sli-routes.yaml
        content: |
          network:
            version: 2
            ethernets:
              eth0:
                routes:
                  - to: 0.0.0.0/0
                    via: ${azurerm_network_interface.sli.private_ip_address}
    runcmd:
      - netplan apply
  CLOUDINIT
}

resource "azurerm_linux_virtual_machine" "test_vm" {
  count               = var.deploy_test_vm ? 1 : 0
  name                = "${local.prefix}-testvm"
  location            = var.location
  resource_group_name = local.resource_group_name
  size                = var.test_vm_size

  network_interface_ids = [
    azurerm_network_interface.test_vm[0].id,
  ]

  admin_username                  = "azureuser"
  disable_password_authentication = true

  admin_ssh_key {
    username   = "azureuser"
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = base64encode(local.test_vm_custom_data)

  boot_diagnostics {}

  tags = local.common_tags

  depends_on = [
    azurerm_network_interface_security_group_association.test_vm,
  ]
}
