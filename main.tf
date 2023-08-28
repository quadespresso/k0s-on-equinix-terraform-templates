provider "equinix" {
  max_retries             = 3
  max_retry_wait_seconds  = 30
}

locals {
  # Reserved hardware calculations
  total_reserved_hardware   = length(var.metros[0].reserved_hardware)
  master_reserved_hardware  = var.use_reserved_hardware ? min(var.master_count, local.total_reserved_hardware) : 0
  worker_reserved_hardware  = var.use_reserved_hardware ? min(var.worker_count, local.total_reserved_hardware - local.master_reserved_hardware) : 0

  # IP calculations
  all_ips_list              = [for i in range(0, pow(2, (32 - split("/", module.common.reserved_ip_cidr)[1])) - 2) : cidrhost(module.common.reserved_ip_cidr, i+2)]
  all_ips                   = { for idx, ip in local.all_ips_list : format("sv-%d", idx) => ip }
  master_ips                = var.master_count > 0 ? { for k, v in local.all_ips : k => v if tonumber(substr(k, 3, -1)) < var.master_count } : {}
  master_count_actual       = length(local.master_ips)
  worker_ips                = { for idx in range(0, var.worker_count) : format("sv-%d", idx) => local.all_ips[format("sv-%d", idx + local.master_count_actual)] }

  # IP block size calculation
  required_ips              = var.master_count + var.worker_count + 6
  nearest_power_of_2        = ceil(pow(2, ceil(log(local.required_ips, 2))))
  ip_block_size             = local.nearest_power_of_2
  
  # Hosts for MKE cluster
  master_public_ips         = module.masters.public_ips
  worker_public_ips         = module.workers.public_ips

  managers = [for ip in local.master_public_ips : {
    ssh = {
      address = ip
      user    = "root"
      keyPath = "./ssh_keys/${var.cluster_name}.pem"
    }
    role = "manager"
  }]

  workers = [for ip in local.worker_public_ips : {
    ssh = {
      address = ip
      user    = "root"
      keyPath = "./ssh_keys/${var.cluster_name}.pem"
    }
    role = "worker"
  }]

  # Define the base mke map
  base_mke = {
    version       = var.mke_version
    adminUsername = "admin"
    adminPassword = var.admin_password
    installFlags  = [
      "--default-node-orchestrator=kubernetes",
      "--pod-cidr 172.16.0.0/16",
      "--service-cluster-ip-range=172.17.0.0/16",
    ]
  }

  # Merge the licenseFilePath if it's not null
  license_map = var.license_file_path != null ? { licenseFilePath = var.license_file_path } : {}
  merged_mke = merge(local.base_mke, local.license_map)

  # MKE cluster configuration
  launchpad_tmpl = {
    apiVersion = "launchpad.mirantis.com/mke/v1.3"
    kind       = "mke"
    metadata = {
      name = var.cluster_name
    }
    spec = {
      mcr = {
        channel = "stable"
        repoURL = "https://repos.mirantis.com"
        version = var.mcr_version
      }
      mke = local.merged_mke
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
}

module "masters" {
  source                  = "./modules/machine"
  cluster_name            = var.cluster_name
  machine_count           = var.master_count
  ssh_key                 = module.common.ssh_key
  hostname                = "${var.cluster_name}-master"
  vlan                    = module.common.vxlan
  ip_addresses            = local.master_ips
  reserved_ip_cidr        = module.common.reserved_ip_cidr
  ssh_private_key_path    = module.common.private_key_path
  project_id              = var.project_id
  metros                  = [{
    metro                 = "sv",
    reserved_hardware     = slice(var.metros[0].reserved_hardware, 0, local.master_reserved_hardware)
  }]
}

module "workers" {
  source                  = "./modules/machine"
  cluster_name            = var.cluster_name
  machine_count           = var.worker_count
  ssh_key                 = module.common.ssh_key
  hostname                = "${var.cluster_name}-worker"
  vlan                    = module.common.vxlan
  ip_addresses            = local.worker_ips
  reserved_ip_cidr        = module.common.reserved_ip_cidr
  ssh_private_key_path    = module.common.private_key_path
  project_id              = var.project_id
  metros                  = [{
    metro                 = "sv",
    reserved_hardware     = slice(var.metros[0].reserved_hardware, local.master_reserved_hardware, local.master_reserved_hardware + local.worker_reserved_hardware)
  }]
}

output "mke_cluster" {
  value = yamlencode(local.launchpad_tmpl)
}
