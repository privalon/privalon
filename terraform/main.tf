locals {
  injected_ssh_keys_list = distinct([
    for k in concat(
      var.ssh_public_keys,
      trimspace(var.ssh_public_key) != "" ? [var.ssh_public_key] : [],
      trimspace(var.ssh_public_key_path) != "" ? [try(file(pathexpand(var.ssh_public_key_path)), "")] : []
    ) : trimspace(k)
    if trimspace(k) != ""
  ])

  injected_ssh_key = join("\n", local.injected_ssh_keys_list)
}

locals {
  gateway_deployment_name = "${var.name}_gateway"
  control_deployment_name = "${var.name}_control"
  workload_deployment_names = {
    for name in keys(var.workloads) : name => "${var.name}_${name}"
  }

  # TFGrid enforces globally unique network names. Append deployment_tag (date/time)
  # so each fresh deploy gets a unique name and avoids "global workload ... exists: conflict".
  # deploy.sh generates and caches the tag; re-runs use the same cached value.
  network_name = var.deployment_tag != "" ? "${var.name}_${var.deployment_tag}" : var.name

  # Which VMs need scheduler-picked nodes?
  scheduler_request_names = distinct(concat(
    var.gateway_node_id == null ? ["gateway"] : [],
    var.control_node_id == null ? ["control"] : [],
    [for name, w in var.workloads : name if try(w.node_id, null) == null]
  ))

  scheduler_enabled = var.use_scheduler && length(local.scheduler_request_names) > 0
}

resource "grid_scheduler" "sched" {
  for_each = local.scheduler_enabled ? { for name in local.scheduler_request_names : name => name } : {}

  dynamic "requests" {
    for_each = [each.key]
    content {
      name = requests.value

      # Public VMs
      cru              = contains(["gateway", "control"], requests.value) ? var.scheduler_public.cru : var.scheduler_private.cru
      mru              = contains(["gateway", "control"], requests.value) ? var.scheduler_public.mru : var.scheduler_private.mru
      sru              = contains(["gateway", "control"], requests.value) ? var.scheduler_public.sru : var.scheduler_private.sru
      public_config    = contains(["gateway", "control"], requests.value) ? var.scheduler_public.public_config : var.scheduler_private.public_config
      public_ips_count = contains(["gateway", "control"], requests.value) ? var.scheduler_public.public_ips : var.scheduler_private.public_ips
      node_exclude     = contains(["gateway", "control"], requests.value) ? var.scheduler_public.node_exclude : var.scheduler_private.node_exclude
      distinct         = contains(["gateway", "control"], requests.value) ? var.scheduler_public.distinct : var.scheduler_private.distinct

      yggdrasil = false
      wireguard = false
    }
  }
}

locals {
  resolved_gateway_node_id = var.gateway_node_id != null ? var.gateway_node_id : (local.scheduler_enabled ? try(grid_scheduler.sched["gateway"].nodes["gateway"], null) : null)
  resolved_control_node_id = var.control_node_id != null ? var.control_node_id : (local.scheduler_enabled ? try(grid_scheduler.sched["control"].nodes["control"], null) : null)

  resolved_workload_node_ids = {
    for name, w in var.workloads :
    name => (try(w.node_id, null) != null ? w.node_id : (local.scheduler_enabled ? try(grid_scheduler.sched[name].nodes[name], null) : null))
  }

  vm_node_ids = merge(
    {
      gateway = local.resolved_gateway_node_id
      control = local.resolved_control_node_id
    },
    local.resolved_workload_node_ids
  )

  mycelium_keys_by_node_grouped = {
    for vm_name, node_id in local.vm_node_ids :
    tostring(node_id) => random_bytes.network_mycelium_key[vm_name].hex...
    if node_id != null
  }

  mycelium_keys_by_node = {
    for node_id, keys in local.mycelium_keys_by_node_grouped :
    node_id => keys[0]
  }

  network_node_ids = distinct([
    for id in concat(
      [local.resolved_gateway_node_id, local.resolved_control_node_id],
      values(local.resolved_workload_node_ids)
    ) : id if id != null
  ])
}

resource "random_bytes" "network_mycelium_key" {
  for_each = toset(concat(["gateway", "control"], keys(var.workloads)))
  length   = 32
}

resource "random_bytes" "mycelium_seed" {
  for_each = toset(concat(["gateway", "control"], keys(var.workloads)))
  length   = 6
}

resource "grid_network" "net" {
  name          = local.network_name
  nodes         = local.network_node_ids
  ip_range      = var.network_ip_range
  add_wg_access = false

  mycelium_keys = local.mycelium_keys_by_node
}

resource "grid_deployment" "gateway" {
  name         = local.gateway_deployment_name
  node         = local.resolved_gateway_node_id
  network_name = grid_network.net.name

  vms {
    name        = "gateway"
    flist       = var.gateway.flist
    cpu         = var.gateway.cpu
    memory      = var.gateway.memory_mb
    rootfs_size = var.gateway.rootfs_mb
    entrypoint  = var.gateway.entrypoint
    publicip    = true

    mycelium_ip_seed = random_bytes.mycelium_seed["gateway"].hex

    env_vars = {
      SSH_KEY = local.injected_ssh_key
      VM_ROLE = "gateway"
    }
  }
}

resource "grid_deployment" "control" {
  name         = local.control_deployment_name
  node         = local.resolved_control_node_id
  network_name = grid_network.net.name

  # Control VM (Headscale)
  vms {
    name        = "control"
    flist       = var.control.flist
    cpu         = var.control.cpu
    memory      = var.control.memory_mb
    rootfs_size = var.control.rootfs_mb
    entrypoint  = var.control.entrypoint
    publicip    = true

    mycelium_ip_seed = random_bytes.mycelium_seed["control"].hex

    env_vars = {
      SSH_KEY = local.injected_ssh_key
      VM_ROLE = "control"
    }
  }
}

resource "grid_deployment" "workloads" {
  for_each     = var.workloads
  name         = local.workload_deployment_names[each.key]
  node         = local.resolved_workload_node_ids[each.key]
  network_name = grid_network.net.name

  vms {
    name        = each.key
    flist       = each.value.flist
    cpu         = each.value.cpu
    memory      = each.value.memory_mb
    rootfs_size = each.value.rootfs_mb
    entrypoint  = each.value.entrypoint
    publicip    = false

    mycelium_ip_seed = random_bytes.mycelium_seed[each.key].hex

    env_vars = merge(
      {
        SSH_KEY = local.injected_ssh_key
        VM_ROLE = "workload"
        VM_NAME = each.key
      },
      each.value.env_vars
    )
  }
}
