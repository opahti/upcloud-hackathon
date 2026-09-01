# Set values in terraform.tfvars (see terraform.tfvars.example).

variable "ssh_public_key" {
  description = "SSH public key installed on every server, used for interactive access and by deploy.sh."
  type        = string
}

variable "control_zone" {
  description = "Zone for the control plane (flag API, edge fanout, dashboard)."
  type        = string
  default     = "fi-hel1"
}

variable "edge_zones" {
  description = "Zones that get an edge node. Available zones: `upctl zone list` or the UpCloud documentation. Adding or removing a zone here and re-applying creates or destroys exactly that zone's resources."
  type        = list(string)
  default     = ["de-fra1", "uk-lon1", "us-nyc1", "us-sjo1", "sg-sin1", "au-syd1"]
}

variable "plan" {
  description = "Server plan. The smallest fixed plan is sufficient: nodes hold a small flag set in memory."
  type        = string
  default     = "1xCPU-1GB"
}

variable "private_cidr" {
  description = "Address space carved into one /24 subnet per zone for the private networks."
  type        = string
  default     = "10.42.0.0/16"
}

variable "enable_postgres" {
  description = "Create a Managed PostgreSQL instance for durable flag persistence. The control plane runs file-backed without it."
  type        = bool
  default     = false
}
