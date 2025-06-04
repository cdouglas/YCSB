provider "azurerm" {
  features {}
}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  clients = [for i in range(1, 13) : "client${i}"]
}

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

resource "azurerm_storage_account" "adls_premium" {
  name                     = "${var.storage_account_name}${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = var.location
  account_tier             = "Premium"
  account_replication_type = "LRS"
  account_kind             = "BlockBlobStorage"

  is_hns_enabled = true

  tags = {
    purpose = "ycsb-benchmark"
  }
}

resource "azurerm_storage_container" "container" {
  name                  = var.storage_container_name
  storage_account_name  = azurerm_storage_account.adls_premium.name
  container_access_type = "private"
}

data "azurerm_storage_account_sas" "sas_tokens" {
  for_each          = toset(local.clients)
  connection_string = azurerm_storage_account.adls_premium.primary_connection_string
  https_only        = true
  start             = timestamp()
  expiry            = timeadd(timestamp(), var.sas_expiry_duration)

  resource_types {
    service   = true
    container = true
    object    = true
  }

  services {
    blob   = true
    file   = false
    queue  = false
    table  = false
  }

  permissions {
    read    = true
    write   = true
    add     = true
    create  = true
    delete  = false
    list    = false
    process = false
    update  = false
    tag     = false
    filter  = false
  }
}