# ============================================================================
# SERVERS — one control plane + one edge per zone in var.edge_zones.
#
# Both use cloud-init (the user_data field) for first-boot setup: install
# Node, write /etc/ripple.env, register a systemd unit. Application CODE is
# NOT baked in — ../deploy.sh rsyncs it after apply. That split keeps the
# infra layer stable while you iterate on code all weekend.
# ============================================================================

resource "upcloud_server" "control" {
  hostname = "ripple-control"
  zone     = var.control_zone
  plan     = var.plan
  metadata = true # required for cloud-init user_data to be served

  template {
    storage = "Ubuntu Server 24.04 LTS (Noble Numbat)" # template by name
    size    = 25                                       # GB, matches the plan
  }

  # Interface order matters: index 0 = public, index 1 = private.
  # outputs.tf and edge user_data rely on that ordering.
  network_interface {
    type = "public"
  }
  network_interface {
    type    = "private"
    network = upcloud_network.zone[var.control_zone].id
  }

  login {
    user            = "root" # hackathon-pragmatic; use a sudo user + firewall rules for anything real
    keys            = [var.ssh_public_key]
    create_password = false
  }

  # templatefile() renders cloud-init/node.yaml.tftpl with these variables.
  user_data = templatefile("${path.module}/cloud-init/node.yaml.tftpl", {
    role                 = "control-plane"
    entry                = "server.js"
    zone                 = var.control_zone
    port                 = 4000
    control_plane_ws     = "" # the control plane doesn't dial anyone
    control_plane_ws_alt = ""
  })
}

resource "upcloud_server" "edge" {
  for_each = toset(var.edge_zones) # one server per zone; for_each needs a set/map

  hostname = "ripple-edge-${each.key}"
  zone     = each.key
  plan     = var.plan
  metadata = true

  template {
    storage = "Ubuntu Server 24.04 LTS (Noble Numbat)"
    size    = 25
  }

  network_interface {
    type = "public"
  }
  network_interface {
    type    = "private"
    network = upcloud_network.zone[each.key].id
  }

  login {
    user            = "root"
    keys            = [var.ssh_public_key]
    create_password = false
  }

  # Edges dial the control plane over the PRIVATE address first (cross-zone
  # traffic rides UpCloud's backbone via the shared router — that's the SDN
  # story in your pitch), and fall back to the public IP if that path is down.
  user_data = templatefile("${path.module}/cloud-init/node.yaml.tftpl", {
    role                 = "edge"
    entry                = "edge.js"
    zone                 = each.key
    port                 = 4100
    control_plane_ws     = "ws://${upcloud_server.control.network_interface[1].ip_address}:4000/ws/edge"
    control_plane_ws_alt = "ws://${upcloud_server.control.network_interface[0].ip_address}:4000/ws/edge"
  })
}

# ----------------------------------------------------------------------------
# Day-2 upgrade: Managed PostgreSQL for flag persistence.
# `count` is the older cousin of for_each — here it's a conditional:
# 1 copy if enabled, 0 if not. Flip enable_postgres = true in tfvars,
# `terraform apply`, and wire DATABASE_URL into the control plane.
# ----------------------------------------------------------------------------
resource "upcloud_managed_database_postgresql" "flags" {
  count = var.enable_postgres ? 1 : 0

  name  = "ripple-flags"
  title = "ripple flag store"
  zone  = var.control_zone
  plan  = "1x1xCPU-2GB-25GB" # smallest plan

  properties {
    public_access = true # fine for a hackathon; private-network attach is the polished version
  }
}
