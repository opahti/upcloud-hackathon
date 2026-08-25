# ============================================================================
# Variables are the knobs of a Terraform config. Each one can be set (in
# priority order) by: -var on the CLI, a terraform.tfvars file, a TF_VAR_*
# environment variable, or fall back to the default written here.
#
# Copy terraform.tfvars.example -> terraform.tfvars and edit that.
# ============================================================================

variable "ssh_public_key" {
  description = "Your SSH public key (contents of ~/.ssh/id_ed25519.pub) — gets installed on every server so you and deploy.sh can ssh in."
  type        = string
  # No default on purpose: Terraform will refuse to run until you provide it.
  # That's how you mark a variable as required.
}

variable "control_zone" {
  description = "Zone for the control plane (admin API + wall UI)."
  type        = string
  default     = "fi-hel1"
}

variable "edge_zones" {
  description = <<-EOT
    Zones that get an edge node. Spread these across continents — the whole
    demo is watching a flag ripple across real geography.
    Check available zones with: upctl zone list  (or the UpCloud docs).
    Adding a zone here and re-running `terraform apply` creates exactly one
    new server + network; removing one destroys just that pair. That diffing
    is the core of what Terraform buys you.
  EOT
  type        = list(string)
  default     = ["de-fra1", "uk-lon1", "us-nyc1", "us-sjo1", "sg-sin1", "au-syd1"]
}

variable "plan" {
  description = "Server size. 1xCPU-1GB is the smallest fixed plan and plenty for a node that holds a few flags in memory."
  type        = string
  default     = "1xCPU-1GB"
}

variable "private_cidr" {
  description = "Address space carved into one /24 subnet per zone for the private SDN networks."
  type        = string
  default     = "10.42.0.0/16"
}

variable "enable_postgres" {
  description = "Set true to also create a Managed PostgreSQL for flag persistence (day-2 upgrade; the app runs file-backed without it)."
  type        = bool
  default     = false
}
