# Ripple

A feature-flag service with an edge cache in every UpCloud region — and a
wall-sized dashboard where flipping a flag visibly ripples across the planet,
with real propagation milliseconds printed on every region.

```
                        ┌──────────────────────────┐
   admin / wall UI ───► │  control plane (fi-hel1) │  flags in PostgreSQL/file
                        │  HTTP :4000  WS /ws/edge │
                        └────────────┬─────────────┘
              private SDN: per-zone │ routers + network peerings (public fallback)
        ┌──────────────┬─────────────┼──────────────┬───────────────┐
        ▼              ▼             ▼              ▼               ▼
   edge de-fra1   edge uk-lon1  edge us-nyc1   edge sg-sin1   edge au-syd1
   flags in RAM, served locally on :4100 — keeps serving if control plane dies
```

- **Propagation is measured honestly**: the control plane stamps t0 when it
  sends an update and stops the clock when the edge's ack returns. One clock,
  no skew games; the number is a truthful upper bound.
- **Resilience finale**: kill the control plane live — every edge keeps
  serving flags from memory, status flips to `stale`.

## Repo layout

| Path | What |
|---|---|
| `terraform/` | The whole fleet as code — heavily commented, read it top to bottom starting at `providers.tf` |
| `services/control-plane/` | Flag API + edge fanout + the Wall (`public/index.html`) |
| `services/edge/` | Edge node: WS subscribe, in-memory cache, local read API |
| `sdk/` | The deliberately tiny client SDK |
| `deploy.sh` | rsync code to the fleet Terraform built, restart services |

## Run locally first (no cloud needed)

```sh
cd services/control-plane && npm install && npm start
# second terminal — a fake Frankfurt:
cd services/edge && npm install && ZONE=de-fra1 PORT=4101 npm start
# third terminal — a fake Sydney:
ZONE=au-syd1 PORT=4102 npm start
```

Open http://localhost:4000, flip `party_mode`, watch both tiles ripple.
Kill the control plane (`ctrl-C`) and check an edge still answers:
`curl localhost:4101/flags` → `"status":"stale"`, flags intact.

## Terraform crash course (10 minutes)

Install, then read `terraform/providers.tf` — the concepts are commented
inline where they're used, in reading order:

```sh
brew install hashicorp/tap/terraform   # or: brew install opentofu (drop-in FOSS fork)
```

The mental model in four sentences: **`.tf` files declare what should
exist**; `terraform apply` makes reality match and records what it made in
**state** (`terraform.tfstate` — precious, gitignored); editing a file and
re-applying computes a **diff** and changes only that; **`terraform destroy`**
deletes everything the state knows about. Concepts you'll meet in this repo:
`provider` (the UpCloud plugin), `resource` (one real thing), `variable` /
`terraform.tfvars` (inputs), `locals` (computed constants), `for_each` (stamp
out N copies from a list — how one block becomes six edge servers), resource
references like `upcloud_router.ripple.id` (which also define build order),
`templatefile()` (render cloud-init with variables), and `output` (exports
that `deploy.sh` reads with `-json`).

Daily commands: `terraform plan` before every apply (free dry run),
`terraform fmt` (autoformat), `terraform output` (see exports again),
`terraform state list` (what exists), `terraform destroy -target=upcloud_server.edge[\"au-syd1\"]`
(surgical removal — but usually just edit `edge_zones` and apply).

## Deploy the real fleet

```sh
# 1. Credentials — make a separate API user in the UpCloud hub first
export UPCLOUD_USERNAME=... UPCLOUD_PASSWORD=...

# 2. Your settings
cd terraform
cp terraform.tfvars.example terraform.tfvars   # paste in your SSH public key

# 3. The Terraform loop
terraform init
terraform plan     # read this! it lists every resource it will create
terraform apply    # ~1-2 min for the whole fleet

# 4. Ship the code and open the wall
cd .. && ./deploy.sh
```

Iterating during the weekend: code change → `./deploy.sh` (or
`./deploy.sh edges`). Infra change → edit `.tf` → `plan` → `apply`.
**When you stop for the night: `terraform destroy`** — recreating the whole
fleet in the morning is two commands and saves credits.

Debugging a node: `ssh root@<ip>` then `journalctl -u ripple -f`.
Cloud-init log (first-boot issues): `cat /var/log/cloud-init-output.log`.

## Demo script

1. Hand a judge the wall. They flip `party_mode` → the change sweeps zone by
   zone with real ms — Helsinki single digits, Sydney a couple hundred.
2. Drag `new_checkout` rollout to 30% → sticky per-unit bucketing via the SDK.
3. Finale: `ssh root@<control-ip> systemctl stop ripple` → every tile keeps
   its flags, edges go `stale`, nothing breaks. Restart it, watch them resync.

## Day-2 board

- [ ] The Wall, but gorgeous: world-map tile placement, arcs from control zone on each flip
- [ ] Percentage rollout rendered as a grid of mini-units per zone (30% flip = a third of dots change)
- [ ] `enable_postgres = true` + wire `DATABASE_URL` into the control plane (Managed PostgreSQL is already in `servers.tf`)
- [ ] Audience phones join as extra "regions" (an edge-ish page that subscribes and shows its own latency)
- [ ] Managed Load Balancer in front of the control plane — one more UpCloud product in the pitch
