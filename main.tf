provider "equinix" {
  max_retries             = 3
  max_retry_wait_seconds  = 30
}

locals {
  ip2int = { for ip in local.all_ips_list : ip => 
    tonumber(split(".", ip)[0]) * 16777216 + 
    tonumber(split(".", ip)[1]) * 65536 + 
    tonumber(split(".", ip)[2]) * 256 + 
    tonumber(split(".", ip)[3])
  }

  # Reserved hardware calculations
  total_reserved_hardware   = length(var.metros[0].reserved_hardware)
  master_reserved_hardware  = var.use_reserved_hardware ? min(var.master_count, local.total_reserved_hardware) : 0
  worker_reserved_hardware  = var.use_reserved_hardware ? min(var.worker_count, local.total_reserved_hardware - local.master_reserved_hardware) : 0

  # IP calculations
  all_ips_list              = [for i in range(0, pow(2, (32 - split("/", module.common.reserved_ip_cidr)[1])) - 2) : cidrhost(module.common.reserved_ip_cidr, i+2)]
  all_ips                   = { for idx, ip in local.all_ips_list : format("%s-%d", var.metros[0].metro, idx) => ip }
  master_ips                = var.master_count > 0 ? { for k, v in local.all_ips : k => v if tonumber(substr(k, 3, -1)) < var.master_count } : {}
  master_count_actual       = length(local.master_ips)
  worker_ips = {
    for idx in range(0, var.worker_count) :
    format("%s-%d", var.metros[0].metro, idx) => local.all_ips[format("%s-%d", var.metros[0].metro, idx + local.master_count_actual)]
  }

  # IPs used by masters and workers
  used_ips = merge(
    { for k, v in local.master_ips : "master-${k}" => v },
    { for k, v in local.worker_ips : "worker-${k}" => v }
  )

  # IPs available for lb_address_pool
  lb_address_pool = [for ip in local.all_ips_list : ip if !contains(values(local.used_ips), ip)]

  # Convert each IP address in lb_address_pool to its integer representation
  ip2int_map = { for ip in local.lb_address_pool : ip => local.ip2int[ip] }

  # Create a map of integer values to their corresponding IPs
  int_to_ip_map = { for ip, int_val in local.ip2int_map : int_val => ip }

  # Sort the integer values
  sorted_int_values = sort(keys(local.int_to_ip_map))

  # Use the sorted integer values to get the sorted IP list
  lb_address_pool_sorted = [for val in local.sorted_int_values : local.int_to_ip_map[val]]

  # IP Range for lb_address_pool
  lb_address_range = "${local.lb_address_pool_sorted[0]}-${local.lb_address_pool_sorted[length(local.lb_address_pool_sorted)-2]}"

  # IP block size calculation
  required_ips              = var.master_count + var.worker_count + 3 + var.lb_block_size
  nearest_power_of_2        = ceil(pow(2, ceil(log(local.required_ips, 2))))
  ip_block_size             = local.nearest_power_of_2
  
  # Hosts for k0s cluster
  master_public_ips         = module.masters.public_ips
  worker_public_ips         = module.workers.public_ips

  managers = [for ip in local.master_public_ips : {
    ssh = {
      address = ip
      user    = "root"
      keyPath = "./ssh_keys/${var.cluster_name}.pem"
    }
    role = "controller"
  }]

  workers = [for ip in local.worker_public_ips : {
    ssh = {
      address = ip
      user    = "root"
      keyPath = "./ssh_keys/${var.cluster_name}.pem"
    }
    role = "worker"
  }]

  # k0s cluster configuration
  launchpad_tmpl = {
    apiVersion = "k0sctl.k0sproject.io/v1beta1"
    kind       = "Cluster"
    metadata = {
      name = var.cluster_name
    }
    spec = {
      hosts = concat(local.managers, local.workers)
    }
  }
}

module "common" {
  source                 = "./modules/common"
  cluster_name           = var.cluster_name
  project_id             = var.project_id
  metro                  = var.metros[0].metro
  request_ip_block       = var.request_ip_block
  ip_block_size          = local.ip_block_size
  use_reserved_hardware  = var.use_reserved_hardware
  masters_ids            = module.masters.machine_ids
  workers_ids            = module.workers.machine_ids
}

module "masters" {
  source                  = "./modules/machine"
  cluster_name            = var.cluster_name
  machine_count           = var.master_count
  machine_size            = var.machine_size
  ssh_key                 = module.common.ssh_key
  hostname                = "${var.cluster_name}-master"
  vlan                    = module.common.vxlan
  ip_addresses            = local.master_ips
  reserved_ip_cidr        = module.common.reserved_ip_cidr
  ssh_private_key_path    = module.common.private_key_path
  project_id              = var.project_id
  metros                  = [{
    metro                 = var.metros[0].metro,
    reserved_hardware     = slice(var.metros[0].reserved_hardware, 0, local.master_reserved_hardware)
  }]
}

module "workers" {
  source                  = "./modules/machine"
  cluster_name            = var.cluster_name
  machine_count           = var.worker_count
  machine_size            = var.machine_size
  ssh_key                 = module.common.ssh_key
  hostname                = "${var.cluster_name}-worker"
  vlan                    = module.common.vxlan
  ip_addresses            = local.worker_ips
  reserved_ip_cidr        = module.common.reserved_ip_cidr
  ssh_private_key_path    = module.common.private_key_path
  project_id              = var.project_id
  metros                  = [{
    metro                 = var.metros[0].metro,
    reserved_hardware     = slice(var.metros[0].reserved_hardware, 0, local.master_reserved_hardware)
  }]
}
