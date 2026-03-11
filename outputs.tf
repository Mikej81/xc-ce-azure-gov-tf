output "site_name" {
  description = "F5 XC Secure Mesh Site name"
  value       = volterra_securemesh_site_v2.this.name
}

output "site_token" {
  description = "Registration token (valid 24 hours)"
  value       = local.site_token
  sensitive   = true
}

output "resource_group_name" {
  description = "Azure resource group name (created or existing)"
  value       = local.resource_group_name
}

output "vm_name" {
  value = azurerm_linux_virtual_machine.ce.name
}

output "slo_private_ip" {
  value = azurerm_network_interface.slo.private_ip_address
}

output "sli_private_ip" {
  value = azurerm_network_interface.sli.private_ip_address
}

output "slo_public_ip" {
  value = var.create_public_ip ? azurerm_public_ip.slo[0].ip_address : null
}

output "image_id" {
  description = "Azure Image ID (created or provided)"
  value       = local.ce_image_id
}

output "test_vm_private_ip" {
  description = "Test VM private IP on SLI subnet"
  value       = var.deploy_test_vm ? azurerm_network_interface.test_vm[0].private_ip_address : null
}
