#!/usr/bin/env bash
# Push application code to the fleet Terraform created, then (re)start it.
# Terraform owns the machines; this owns what runs on them.
#
#   ./deploy.sh            # deploy control plane + all edges
#   ./deploy.sh edges      # just the edges
#   ./deploy.sh control    # just the control plane
set -euo pipefail
cd "$(dirname "$0")"

command -v jq >/dev/null || { echo "needs jq: brew install jq"; exit 1; }

OUT=$(cd terraform && terraform output -json)
CONTROL_IP=$(jq -r '.control_plane_public_ip.value' <<<"$OUT")
if [[ -z "$CONTROL_IP" || "$CONTROL_IP" == "null" ]]; then
  echo "No fleet in Terraform state — run 'terraform apply' in ./terraform first."
  exit 1
fi
TARGET="${1:-all}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new)

push() { # push <ip> <service-dir> <label>
  local ip=$1 dir=$2 label=$3
  echo "── $label ($ip)"
  # First-boot race guard: cloud-init installs Node and creates /opt/ripple;
  # on a freshly created server it may still be running. Wait it out, and
  # mkdir ourselves since rsync only creates the final path segment.
  ssh "${SSH_OPTS[@]}" "root@$ip" \
    "cloud-init status --wait >/dev/null 2>&1 || true; mkdir -p /opt/ripple/$dir"
  rsync -az --delete -e "ssh ${SSH_OPTS[*]}" \
    --exclude node_modules --exclude flags.json \
    "services/$dir/" "root@$ip:/opt/ripple/$dir/"
  ssh "${SSH_OPTS[@]}" "root@$ip" \
    "cd /opt/ripple/$dir && npm install --omit=dev --silent && systemctl restart ripple"
}

if [[ "$TARGET" == "all" || "$TARGET" == "control" ]]; then
  push "$CONTROL_IP" control-plane "control-plane"
fi

if [[ "$TARGET" == "all" || "$TARGET" == "edges" ]]; then
  # Edges are independent — deploy them in parallel.
  while read -r zone ip; do
    push "$ip" edge "edge $zone" &
  done < <(jq -r '.edge_public_ips.value | to_entries[] | "\(.key) \(.value)"' <<<"$OUT")
  wait
fi

echo
echo "wall: $(jq -r '.wall_url.value' <<<"$OUT")"
