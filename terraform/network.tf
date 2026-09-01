# ============================================================================
# NETWORKING — cross-zone private connectivity.
#
# UpCloud routers are zone-local gateways; attaching networks from multiple
# zones to one router is unsupported (the API rejects it with
# NETWORK_ROUTER_ZONE_CONFLICT). The supported mechanism for private traffic
# between zones is network peering, which requires each network to have its
# own router:
#
#   zone network (10.42.i.0/24) ── zone router ═╗ peering ╔═ control router ── control network
#                                               ╚═════════╝
#
# Hub-and-spoke: one peering per edge zone, all pointing at the control
# zone. This matches the traffic pattern — edges only talk to the control
# plane, never to each other.
# ============================================================================

locals {
  all_zones = concat([var.control_zone], var.edge_zones)

  # Inter-zone peering is only available between geographically nearby zones
  # (the API returns INTERZONE_PEERING_NOT_SUPPORTED otherwise), so only
  # edges in the control zone's region are peered. The rest connect over the
  # public internet via the fallback URL built into the edge application;
  # the dashboard labels each edge's transport accordingly.
  zone_region = {
    fi = "europe", se = "europe", no = "europe", dk = "europe", de = "europe",
    nl = "europe", uk = "europe", es = "europe", pl = "europe",
    us = "us", sg = "apac", au = "apac"
  }
  region_of    = { for z in local.all_zones : z => lookup(local.zone_region, substr(z, 0, 2), "other") }
  peered_edges = [for z in var.edge_zones : z if local.region_of[z] == local.region_of[var.control_zone]]

  # One /24 per zone, carved from the shared /16. Distinct subnets are
  # required: peering rejects overlapping address ranges.
  zone_subnet = { for i, z in local.all_zones : z => cidrsubnet(var.private_cidr, 8, i) }
}

# One router per zone.
resource "upcloud_router" "zone" {
  for_each = local.zone_subnet

  name = "ripple-${each.key}"
}

resource "upcloud_network" "zone" {
  for_each = local.zone_subnet

  name   = "ripple-${each.key}"
  zone   = each.key
  router = upcloud_router.zone[each.key].id

  ip_network {
    address = each.value
    dhcp    = true
    family  = "IPv4"
    # Advertise a route for the whole private range over DHCP, so servers
    # send cross-zone traffic to their zone's router, which forwards it
    # across the peering. Without this, servers only know their own /24.
    dhcp_routes = [var.private_cidr]
  }
}

# Peerings: control zone <-> each edge zone in the same region. A peering
# only activates once it exists in both directions — a one-sided peering
# stays in "Pending peer" status and passes no traffic — hence the two
# resources, one per direction.
resource "upcloud_network_peering" "edge" {
  for_each = toset(local.peered_edges)

  name = "ripple-${var.control_zone}-to-${each.key}"

  network {
    uuid = upcloud_network.zone[var.control_zone].id
  }
  peer_network {
    uuid = upcloud_network.zone[each.key].id
  }
}

resource "upcloud_network_peering" "edge_return" {
  for_each = toset(local.peered_edges)

  name = "ripple-${each.key}-to-${var.control_zone}"

  network {
    uuid = upcloud_network.zone[each.key].id
  }
  peer_network {
    uuid = upcloud_network.zone[var.control_zone].id
  }
}
