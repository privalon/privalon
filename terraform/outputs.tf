output "network_ip_range" {
  description = "Private network CIDR configured for grid_network."
  value       = var.network_ip_range
}

output "gateway_public_ip" {
  description = "Gateway VM reserved public IPv4, without CIDR suffix."
  value       = try(split("/", grid_deployment.gateway.vms[0].computedip)[0], grid_deployment.gateway.vms[0].computedip)
}

output "gateway_public_ip_cidr" {
  description = "Gateway VM reserved public IPv4 as returned by provider (may include CIDR, e.g. x.x.x.x/24)."
  value       = grid_deployment.gateway.vms[0].computedip
}

output "control_public_ip" {
  description = "Control VM reserved public IPv4 (Headscale), without CIDR suffix."
  value       = try(split("/", one([for vm in grid_deployment.core.vms : vm.computedip if vm.name == "control"]))[0], one([for vm in grid_deployment.core.vms : vm.computedip if vm.name == "control"]))
}

output "control_public_ip_cidr" {
  description = "Control VM reserved public IPv4 as returned by provider (may include CIDR, e.g. x.x.x.x/24)."
  value       = one([for vm in grid_deployment.core.vms : vm.computedip if vm.name == "control"])
}

output "gateway_private_ip" {
  description = "Gateway VM private network IP."
  value       = grid_deployment.gateway.vms[0].ip
}

output "control_private_ip" {
  description = "Control VM private network IP."
  value       = one([for vm in grid_deployment.core.vms : vm.ip if vm.name == "control"])
}

output "gateway_mycelium_ip" {
  description = "Gateway VM Mycelium IP (IPv6)."
  value       = grid_deployment.gateway.vms[0].mycelium_ip
}

output "control_mycelium_ip" {
  description = "Control VM Mycelium IP (IPv6)."
  value       = one([for vm in grid_deployment.core.vms : vm.mycelium_ip if vm.name == "control"])
}

output "workloads_private_ips" {
  description = "Map of workload name -> private network IP."
  value       = { for name in keys(var.workloads) : name => one([for vm in grid_deployment.core.vms : vm.ip if vm.name == name]) }
}

output "workloads_mycelium_ips" {
  description = "Map of workload name -> Mycelium IP (IPv6). Useful for uniquely reaching workloads on the same node."
  value       = { for name in keys(var.workloads) : name => one([for vm in grid_deployment.core.vms : vm.mycelium_ip if vm.name == name]) }
}

output "gateway_console_url" {
  description = "Gateway VM console URL (provider-specific)."
  value       = grid_deployment.gateway.vms[0].console_url
}

output "control_console_url" {
  description = "Control VM console URL (provider-specific)."
  value       = one([for vm in grid_deployment.core.vms : vm.console_url if vm.name == "control"])
}

output "workloads_console_urls" {
  description = "Map of workload name -> console URL (provider-specific)."
  value       = { for name in keys(var.workloads) : name => one([for vm in grid_deployment.core.vms : vm.console_url if vm.name == name]) }
}
