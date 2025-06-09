provider "azurerm" {
  features {}
  use_cli = true
  subscription_id = "4a4ddf5f-00f1-4bf2-b2d6-3fb5aef3683d"
}

resource "azurerm_resource_group" "ycsb" {
  name     = "ycsb-rg-x"
  location = var.azure_region
}

resource "azurerm_virtual_network" "ycsb" {
  name                = "ycsb-vnet-x"
  address_space       = ["10.0.0.0/16"]
  location            = var.azure_region
  resource_group_name = azurerm_resource_group.ycsb.name
}

resource "azurerm_network_security_group" "ycsb" {
  name                = "ycsb-nsg-x"
  location            = var.azure_region
  resource_group_name = azurerm_resource_group.ycsb.name

  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet" "ycsb" {
  name                 = "ycsb-subnet"
  resource_group_name  = azurerm_resource_group.ycsb.name
  virtual_network_name = azurerm_virtual_network.ycsb.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet_network_security_group_association" "ycsb" {
  subnet_id                 = azurerm_subnet.ycsb.id
  network_security_group_id = azurerm_network_security_group.ycsb.id
}

resource "azurerm_public_ip" "ycsb" {
  name                = "ycsb-ip-x"
  location            = var.azure_region
  resource_group_name = azurerm_resource_group.ycsb.name
  allocation_method   = "Static"
  sku                 = "Standard"
  sku_tier            = "Regional"
}

resource "azurerm_network_interface" "ycsb" {
  name                = "ycsb-nic"
  location            = var.azure_region
  resource_group_name = azurerm_resource_group.ycsb.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.ycsb.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.ycsb.id
  }
}

resource "azurerm_linux_virtual_machine" "ycsb" {
  name                  = "ycsb-vm-x"
  resource_group_name   = azurerm_resource_group.ycsb.name
  location              = var.azure_region
  size                  = var.vm_size
  admin_username        = "azureuser"
  network_interface_ids = [azurerm_network_interface.ycsb.id]

  admin_ssh_key {
    username   = "azureuser"
    public_key = file(var.ssh_public_key_path)
  }

  identity {
    type = "SystemAssigned"
  }

  boot_diagnostics {
    storage_account_uri = null
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts"
    version   = "latest"
  }

  custom_data = base64encode(<<-EOF
    #!/bin/bash

    usermod -aG docker azureuser

    apt-get update
    apt-get install -y --no-install-recommends build-essential ca-certificates curl git gnupg jq lsb-release openjdk-17-jdk-headless software-properties-common ssh unzip wget

  EOF
  )
}

data "azurerm_storage_account" "existing" {
  name                = var.storage_account_name
  resource_group_name = var.storage_account_resource_group
}

resource "azurerm_role_assignment" "vm_blob_data_contributor" {
  principal_id         = azurerm_linux_virtual_machine.ycsb.identity[0].principal_id
  role_definition_name = "Storage Blob Data Contributor"
  scope                = data.azurerm_storage_account.existing.id
}

output "vm_ip" {
  value = azurerm_public_ip.ycsb.ip_address
}
