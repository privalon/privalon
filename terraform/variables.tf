variable "name" {
  type        = string
  description = "Base name for all resources (letters/numbers/underscore recommended)."
  default     = "tfgrid_blueprint"
}

variable "deployment_tag" {
  type        = string
  description = <<-EOT
    Optional timestamp tag appended to the TFGrid network name to guarantee global uniqueness.
    Format: YYYYMMDD_HHMMSS  (generated automatically by deploy.sh on each new full deploy).
    Cached in environments/<env>/deployment-tag so re-runs use the same name.
    When empty, var.name is used as-is (manual use only).
  EOT
  default     = ""
}

variable "tfgrid_mnemonic" {
  type        = string
  description = "TFChain wallet mnemonic (12 words). Set via TF_VAR_tfgrid_mnemonic in secrets.env."
  sensitive   = true
}

variable "tfgrid_network" {
  type        = string
  description = "ThreeFold Grid network to deploy to: dev|qa|test|main. Put this in terraform.tfvars (gitignored)."

  validation {
    condition     = contains(["dev", "qa", "test", "main"], var.tfgrid_network)
    error_message = "tfgrid_network must be one of: dev, qa, test, main."
  }
}

variable "tfgrid_rmb_timeout" {
  type        = number
  description = "Timeout duration (seconds) for ThreeFold RMB calls. Increase this if network/VM deployments sometimes time out."
  default     = 1800
}

variable "ssh_public_key_path" {
  type        = string
  description = "Optional: path to an SSH public key to inject into VMs via SSH_KEY env var. Used only if ssh_public_keys/ssh_public_key are not set."
  default     = ""

  validation {
    condition     = trimspace(var.ssh_public_key_path) == "" || fileexists(pathexpand(var.ssh_public_key_path))
    error_message = "ssh_public_key_path does not exist on this machine. Use ssh_public_keys/ssh_public_key instead, or point ssh_public_key_path to an existing .pub file."
  }
}

variable "ssh_public_keys" {
  type        = list(string)
  description = "List of SSH public key lines to inject into VMs (recommended). Put this in terraform.tfvars (gitignored)."
  default     = []

  validation {
    condition = (
      length([for k in var.ssh_public_keys : k if trimspace(k) != ""]) > 0 ||
      trimspace(var.ssh_public_key) != "" ||
      trimspace(var.ssh_public_key_path) != ""
    )
    error_message = "Provide at least one SSH key via ssh_public_keys (recommended), ssh_public_key, or ssh_public_key_path."
  }
}

variable "ssh_public_key" {
  type        = string
  description = "Single SSH public key line to inject into VMs (legacy). Prefer ssh_public_keys."
  default     = ""
}

variable "network_ip_range" {
  type        = string
  description = "Private network CIDR (for underlying connectivity). Must be a /16 (e.g. 10.10.0.0/16)."
  default     = "10.10.0.0/16"
}

variable "use_scheduler" {
  type        = bool
  description = "If true, TFGrid auto-picks nodes. If false, you must set gateway_node_id, control_node_id, and workloads[*].node_id. Pinning avoids slow multi-node network creation."
  default     = true
}

variable "gateway_node_id" {
  type        = number
  description = "Pin gateway VM to this TFGrid node ID. Required when use_scheduler=false. Find IDs at dashboard.grid.tf → Nodes."
  default     = null
}

variable "control_node_id" {
  type        = number
  description = "Pin Headscale control VM to this TFGrid node ID. Required when use_scheduler=false."
  default     = null
}

variable "gateway" {
  type = object({
    cpu        = number
    memory_mb  = number
    rootfs_mb  = number
    flist      = string
    entrypoint = string
  })
  description = "Gateway VM sizing and image (public IPv4 enabled)."
  default = {
    cpu        = 2
    memory_mb  = 2048
    rootfs_mb  = 8192
    flist      = "https://hub.grid.tf/tf-official-apps/threefoldtech-ubuntu-22.04.flist"
    entrypoint = "/sbin/zinit init"
  }
}

variable "control" {
  type = object({
    cpu        = number
    memory_mb  = number
    rootfs_mb  = number
    flist      = string
    entrypoint = string
  })
  description = "Headscale control VM sizing and image (public IPv4 enabled)."
  default = {
    cpu        = 2
    memory_mb  = 2048
    rootfs_mb  = 8192
    flist      = "https://hub.grid.tf/tf-official-apps/threefoldtech-ubuntu-22.04.flist"
    entrypoint = "/sbin/zinit init"
  }
}

variable "workloads" {
  type = map(object({
    node_id    = optional(number)
    cpu        = optional(number, 1)
    memory_mb  = optional(number, 1024)
    rootfs_mb  = optional(number, 8192)
    flist      = optional(string, "https://hub.grid.tf/tf-official-apps/threefoldtech-ubuntu-22.04.flist")
    entrypoint = optional(string, "/sbin/zinit init")
    env_vars   = optional(map(string), {})
  }))
  description = "Workload VMs (no public IPv4). Key is workload name. Default topology uses a single monitoring VM; add more services by extending this map. If node_id is omitted and use_scheduler=true, scheduler picks nodes."
  default = {
    monitoring = {
      cpu       = 2
      memory_mb = 4096
      rootfs_mb = 16384
    }
  }

  validation {
    condition     = var.use_scheduler || (var.gateway_node_id != null && var.control_node_id != null && alltrue([for _, w in var.workloads : try(w.node_id, null) != null]))
    error_message = "When use_scheduler=false you must set gateway_node_id, control_node_id, and workloads[*].node_id for all workloads."
  }
}

variable "scheduler_public" {
  type = object({
    cru           = number
    mru           = number
    sru           = number
    public_config = bool
    public_ips    = number
    node_exclude  = list(number)
    distinct      = bool
  })
  description = "Scheduler request knobs for public VMs (gateway/control). Used only when use_scheduler=true and node_id is not pinned."
  default = {
    cru           = 2
    mru           = 2048
    sru           = 1024
    public_config = true
    public_ips    = 1
    node_exclude  = []
    distinct      = true
  }
}

variable "scheduler_private" {
  type = object({
    cru           = number
    mru           = number
    sru           = number
    public_config = bool
    public_ips    = number
    node_exclude  = list(number)
    distinct      = bool
  })
  description = "Scheduler request knobs for private workload VMs. Used only when use_scheduler=true and workload node_id is not pinned."
  default = {
    cru           = 1
    mru           = 1024
    sru           = 1024
    public_config = false
    public_ips    = 0
    node_exclude  = []
    distinct      = false
  }
}
