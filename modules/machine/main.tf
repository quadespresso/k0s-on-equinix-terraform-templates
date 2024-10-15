locals {
  nodes_meta_flat = flatten([
    for m in var.metros : [
      for i in range(var.machine_count) : {
        key = "${m.metro}-${i}",
        value = merge({
          metro                   = m.metro,
          plan                    = (i < length(m.reserved_hardware)) ? m.reserved_hardware[i].plan : var.machine_size,
          hardware_reservation_id = (i < length(m.reserved_hardware)) ? m.reserved_hardware[i].id : ""
        })
      }
    ]
  ])

  nodes_meta = { for item in local.nodes_meta_flat : item.key => item.value }

  indexed_nodes_meta = {
    for k, v in local.nodes_meta :
    k => {
      index = index(keys(local.nodes_meta), k) + 1,
      value = v
    }
  }

  cidr_to_netmask = {
    "32" = "255.255.255.255",
    "31" = "255.255.255.254",
    "30" = "255.255.255.252",
    "29" = "255.255.255.248",
    "28" = "255.255.255.240",
    "27" = "255.255.255.224",
    "26" = "255.255.255.192",
    "25" = "255.255.255.128"
  }

  subnet_mask         = local.cidr_to_netmask[element(split("/", var.reserved_ip_cidr), 1)]
  sliced_ip_addresses = length(var.reserved_ip_addresses) > 1 ? slice(var.reserved_ip_addresses, 1, length(var.reserved_ip_addresses)) : []
}

resource "equinix_metal_device" "machine" {
  for_each = local.indexed_nodes_meta

  hostname                = format("%s-%02d", var.hostname, each.value.index)
  plan                    = each.value.value["plan"]
  hardware_reservation_id = each.value.value["hardware_reservation_id"]
  metro                   = each.value.value.metro
  operating_system        = var.operating_system
  billing_cycle           = var.billing_cycle
  project_id              = var.project_id
  project_ssh_key_ids     = [var.ssh_key]

  # keep only ipv4 addresses, skipping ipv6 management
  ip_address {
    type = "private_ipv4"
    cidr = 31
  }

  ip_address {
    type = "public_ipv4"
    cidr = 31
  }

  connection {
    type        = "ssh"
    host        = self.access_public_ipv4
    user        = "root"
    private_key = file("ssh_keys/${var.cluster_name}.pem")
    timeout     = "2m"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '' >> /etc/network/interfaces",
      "echo 'auto bond0.${var.vlan}' >> /etc/network/interfaces",
      "echo 'iface bond0.${var.vlan} inet static' >> /etc/network/interfaces",
      "echo '    pre-up sleep 5' >> /etc/network/interfaces",
      "echo '    address ${var.ip_addresses[each.key]}' >> /etc/network/interfaces",
      "echo '    netmask ${local.subnet_mask}' >> /etc/network/interfaces",
      "echo '    vlan-raw-device bond0' >> /etc/network/interfaces",
      "systemctl restart networking",
      "useradd --home /var/lib/k0s --shell /sbin/nologin --system --no-create-home kube-apiserver",
    ]
  }
}

# Change network mode to hybrid for the edge instance
resource "equinix_metal_device_network_type" "machine" {
  for_each  = local.indexed_nodes_meta
  device_id = equinix_metal_device.machine[each.key].id
  type      = "hybrid-bonded"
}

resource "equinix_metal_port_vlan_attachment" "machine" {
  for_each  = local.indexed_nodes_meta
  device_id = equinix_metal_device.machine[each.key].id
  port_name = "bond0"
  vlan_vnid = var.vlan
}

