# ============================================================================
# TERRAFORM 101 — start reading here.
#
# Terraform is declarative: these .tf files describe the infrastructure you
# WANT, and Terraform figures out the API calls to make reality match.
# The workflow is always the same three commands, run in this directory:
#
#   terraform init      # downloads the providers declared below (once)
#   terraform plan      # dry run: shows what WOULD change, changes nothing
#   terraform apply     # shows the plan again, asks yes/no, then does it
#   terraform destroy   # tears down everything this config created
#
# Terraform remembers what it has created in terraform.tfstate (a local JSON
# file). That file IS your infrastructure's memory — don't delete it, don't
# commit it to git (it can contain secrets). Re-running apply after editing
# a .tf file computes a diff against the state and only changes what differs.
# ============================================================================

terraform {
  required_version = ">= 1.5.0"

  # Providers are plugins that translate resources into API calls.
  # This one is UpCloud's official provider.
  required_providers {
    upcloud = {
      source  = "UpCloudLtd/upcloud"
      version = "~> 5.0" # any 5.x, but not 6.x — pin majors, they can break
    }
  }
}

# Credentials come from environment variables so they never touch the repo:
#   export UPCLOUD_USERNAME=your-api-user
#   export UPCLOUD_PASSWORD=your-api-password
# (Create a separate API-only user in the UpCloud hub — don't use your main
# login. Newer provider versions also accept UPCLOUD_TOKEN.)
provider "upcloud" {
  # Creating ~14 routers/networks at once trips the API's allocation rate
  # limit (NETWORK_ALLOCATION_RATE_LIMITED, 429). Let the provider retry
  # with backoff instead of failing the whole apply. If it still trips,
  # lower concurrency too: terraform apply -parallelism=3
  retry_max          = 8
  retry_wait_min_sec = 2
  retry_wait_max_sec = 30
}
