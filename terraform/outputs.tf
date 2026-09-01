# Read any time with `terraform output` (-json is consumed by ../deploy.sh).

output "wall_url" {
  description = "URL of the dashboard served by the control plane."
  value       = "http://${upcloud_server.control.network_interface[0].ip_address}:4000"
}

output "control_plane_public_ip" {
  value = upcloud_server.control.network_interface[0].ip_address
}

output "control_plane_private_ip" {
  description = "Address edges use over the private network where a peering exists."
  value       = upcloud_server.control.network_interface[1].ip_address
}

output "edge_public_ips" {
  description = "zone -> public IP, used by ssh and deploy.sh."
  value       = { for z, s in upcloud_server.edge : z => s.network_interface[0].ip_address }
}

output "postgres_uri" {
  description = "Connection URI when enable_postgres = true."
  value       = try(upcloud_managed_database_postgresql.flags[0].service_uri, null)
  sensitive   = true # contains credentials; view with: terraform output postgres_uri
}
