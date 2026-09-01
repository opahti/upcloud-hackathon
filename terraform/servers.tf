# ============================================================================
# SERVERS — one control plane + one edge per zone in var.edge_zones.
#
# Both use cloud-init (user_data) for first-boot setup: install Node.js,
# write /etc/ripple.env, register a systemd unit. Application code is not
# baked into the image — ../deploy.sh rsyncs it after apply — keeping the
# infrastructure layer independent of application releases.
# ============================================================================

resource "upcloud_server" "control" {
  hostname = "ripple-control"
  zone     = var.control_zone
  plan     = var.plan
  metadata = true # required for cloud-init user_data to be served

  template {
    storage = "Ubuntu Server 24.04 LTS (Noble Numbat)"
    size    = 25 # GB, matches the plan
  }

  # Interface order matters: index 0 = public, index 1 = private.
  # outputs.tf and the edge user_data rely on that ordering.
  network_interface {
    type = "public"
  }
  network_interface {
    type    = "private"
    network = upcloud_network.zone[var.control_zone].id
  }

  login {
    user            = "root" # simplification for this project; production setups should use a sudo user and firewall rules
    keys            = [var.ssh_public_key]
    create_password = false
  }

  user_data = templatefile("${path.module}/cloud-init/node.yaml.tftpl", {
    role                 = "control-plane"
    entry                = "server.js"
    zone                 = var.control_zone
    port                 = 4000
    control_plane_ws     = "" # the control plane makes no outbound connections
    control_plane_ws_alt = ""
  })
}

resource "upcloud_server" "edge" {
  for_each = toset(var.edge_zones)

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

  # Edges dial the control plane's private address first (cross-zone traffic
  # stays on UpCloud's private backbone where a peering exists) and fall
  # back to the public address if the private path is unavailable.
  user_data = templatefile("${path.module}/cloud-init/node.yaml.tftpl", {
    role                 = "edge"
    entry                = "edge.js"
    zone                 = each.key
    port                 = 4100
    control_plane_ws     = "ws://${upcloud_server.control.network_interface[1].ip_address}:4000/ws/edge"
    control_plane_ws_alt = "ws://${upcloud_server.control.network_interface[0].ip_address}:4000/ws/edge"
  })
}

# Optional Managed PostgreSQL for durable flag persistence. Disabled by
# default; the control plane runs file-backed without it. Enable with
# enable_postgres = true and wire the service URI into the control plane
# as DATABASE_URL.
resource "upcloud_managed_database_postgresql" "flags" {
  count = var.enable_postgres ? 1 : 0

  name  = "ripple-flags"
  title = "ripple flag store"
  zone  = var.control_zone
  plan  = "1x1xCPU-2GB-25GB" # smallest available plan

  properties {
    public_access = true # simplification; production setups should attach to the private network instead
  }
}
