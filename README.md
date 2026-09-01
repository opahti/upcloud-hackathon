# Ripple

A feature-flag service with an in-memory edge cache in every UpCloud region,
and a dashboard that visualizes flag propagation across regions in real time
with measured per-region latencies.

```
                        ┌──────────────────────────┐
   admin / dashboard ─► │  control plane (fi-hel1) │  flag store (file-backed,
                        │  HTTP :4000  WS /ws/edge │  optional PostgreSQL)
                        └────────────┬─────────────┘
              private network via    │    peerings (public fallback)
        ┌──────────────┬─────────────┼──────────────┬───────────────┐
        ▼              ▼             ▼              ▼               ▼
   edge de-fra1   edge uk-lon1  edge us-nyc1   edge sg-sin1   edge au-syd1
   full flag set in RAM, served locally on :4100 — keeps serving if the
   control plane is unreachable
```

Key properties:

- **Reads are local.** Applications read flags from their region's edge node;
  reads never cross a region boundary and never touch the control plane.
- **Propagation is measured on a single clock.** The control plane timestamps
  an update when it broadcasts and stops the clock when each edge's
  acknowledgment returns. No cross-machine timestamps are compared, so the
  figure is immune to clock skew; it includes the acknowledgment's return
  leg, making it an honest upper bound.
- **Read availability over write freshness.** If the control plane goes down,
  edges keep serving their last-known state (marked `stale`) and resync on
  reconnect. Client SDKs additionally fall back to their last cached value.
- **Sticky percentage rollouts.** Deterministic FNV-1a bucketing of
  `flag:unit` into 100 buckets — no coordination between regions, and a unit
  admitted at 30% remains admitted at 50%.

## Repository layout

| Path | Contents |
|---|---|
| `terraform/` | All infrastructure: servers, per-zone private networks and routers, cross-zone peerings |
| `services/control-plane/` | Flag API, edge fanout, propagation measurement, and the dashboard (`public/index.html`) |
| `services/edge/` | Edge node: WebSocket subscription, in-memory cache, local read API |
| `sdk/` | Minimal client SDK |
| `deploy.sh` | Pushes application code to the fleet and restarts services |

## Running locally

No cloud resources required:

```sh
cd services/control-plane && npm install && npm start
# second terminal:
cd services/edge && npm install && ZONE=de-fra1 PORT=4101 npm start
# optionally more edges with other ZONE/PORT values
```

Open http://localhost:4000 and change a flag. Stopping the control plane
demonstrates the availability model: `curl localhost:4101/flags` continues to
answer with `"status":"stale"`.

## Deploying

```sh
export UPCLOUD_USERNAME=... UPCLOUD_PASSWORD=...   # dedicated API subaccount

cd terraform
cp terraform.tfvars.example terraform.tfvars       # set your SSH public key and zones
terraform init
terraform plan
terraform apply

cd .. && ./deploy.sh
```

`terraform apply` provisions the fleet (a couple of minutes); `deploy.sh`
waits for cloud-init to finish on each node, rsyncs the services, and
restarts them. Iterating on code is `./deploy.sh` (or `./deploy.sh edges` /
`./deploy.sh control` for one tier); infrastructure changes go through
`terraform plan` / `apply`. Destroy the fleet with `terraform destroy` when
it is not needed — recreating it is the same two commands.

Note: edges connect to the control plane's private address first with a
public fallback. If edges come up before the network peerings have activated
(possible on a fresh apply), they connect over the public path and stay
there; a `./deploy.sh edges` restarts them onto the private path.

## Troubleshooting

- Per-node logs: `ssh root@<ip>` then `journalctl -u ripple -f`
- First-boot/cloud-init issues: `cat /var/log/cloud-init-output.log`
- Private-path connectivity: from an edge, `ip route` should show the
  private /16 routed via the zone router, and the control plane's private
  address should answer pings where a peering is active.
