terraform {
  required_version = ">= 1.3.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.49.0"
    }

    volterra = {
      source  = "volterraedge/volterra"
      version = ">= 0.11.42"
    }

    random = {
      source  = "hashicorp/random"
      version = ">= 3.4.0"
    }
  }
}

provider "azurerm" {
  features {}
  environment = "usgovernment"
}

provider "volterra" {
  api_p12_file = var.f5xc_api_p12_file
  url          = var.f5xc_api_url
}
