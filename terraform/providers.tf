terraform {
  required_version = ">= 1.5.0"

  required_providers {
    upcloud = {
      source  = "UpCloudLtd/upcloud"
      version = "~> 5.0"
    }
  }
}

# Credentials come from environment variables so they never enter the repo:
#   export UPCLOUD_USERNAME=<api-user>
#   export UPCLOUD_PASSWORD=<api-password>
# Use a dedicated API-only subaccount. Newer provider versions also accept
# UPCLOUD_TOKEN.
provider "upcloud" {
  # Creating many routers/networks in parallel can trip the API's allocation
  # rate limit (NETWORK_ALLOCATION_RATE_LIMITED, 429); retry with backoff
  # instead of failing the apply. If it still triggers, reduce concurrency
  # with: terraform apply -parallelism=3
  retry_max          = 8
  retry_wait_min_sec = 2
  retry_wait_max_sec = 30
}
