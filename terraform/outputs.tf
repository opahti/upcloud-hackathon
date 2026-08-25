# ============================================================================
# Outputs are what a config exports: printed after `terraform apply`, and
# readable any time with `terraform output` (add -json for scripts — that's
# exactly what ../deploy.sh does).
# ============================================================================

output "wall_url" {
  description = "The Ripple Wall — open this on the big screen."
  value       = "http://${upcloud_server.control.network_interface[0].ip_address}:4000"
}

output "control_plane_public_ip" {
  value = upcloud_server.control.network_interface[0].ip_address
}

output "control_plane_private_ip" {
  description = "What the edges dial over the SDN."
  value       = upcloud_server.control.network_interface[1].ip_address
}

output "edge_public_ips" {
  description = "zone -> public IP, for ssh and deploy.sh."
  value       = { for z, s in upcloud_server.edge : z => s.network_interface[0].ip_address }
}

output "postgres_uri" {
  description = "Connection URI when enable_postgres = true."
  # try() because the resource has 0 instances unless enabled.
  value     = try(upcloud_managed_database_postgresql.flags[0].service_uri, null)
  sensitive = true # contains the password; view with: terraform output postgres_uri
}
