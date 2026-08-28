// Ripple edge node: holds the full flag set in memory, subscribed to the
// control plane over WebSocket. Local reads never leave this process — and
// keep working if the control plane dies (status just flips to "stale").
// That's the resilience finale of the demo.

import http from 'node:http';
import os from 'node:os';
import WebSocket from 'ws';

const ZONE = process.env.ZONE || 'local';
const PORT = Number(process.env.PORT || 4100);

// Private-SDN address first, public fallback second (see servers.tf).
const CONTROL_URLS = [process.env.CONTROL_PLANE_WS, process.env.CONTROL_PLANE_WS_ALT]
  .filter(Boolean);
if (CONTROL_URLS.length === 0) CONTROL_URLS.push('ws://localhost:4000/ws/edge');

const flags = new Map(); // name -> flag
let status = 'connecting'; // connecting | live | stale

// ---------------------------------------------------------------------------
// Control-plane subscription with fallback + reconnect.
// ---------------------------------------------------------------------------
let urlIndex = 0;

function connect() {
  const url = CONTROL_URLS[urlIndex % CONTROL_URLS.length];
  const ws = new WebSocket(url, { handshakeTimeout: 5000 });

  ws.on('open', () => {
    console.log(`[${ZONE}] connected to ${url}`);
    // `via` tells the control plane which path we came in on, so the wall
    // can label this edge sdn (private peering) vs public internet.
    // `ips` are our own addresses, shown on the wall for ssh/curl access.
    ws.send(JSON.stringify({ type: 'hello', zone: ZONE, via: url, ips: myIps() }));
  });

  ws.on('message', (raw) => {
    const msg = JSON.parse(raw);

    if (msg.type === 'snapshot') {
      flags.clear();
      for (const f of msg.flags) flags.set(f.name, f);
      status = 'live';
    }

    if (msg.type === 'update') {
      flags.set(msg.flag.name, msg.flag);
      // Ack AFTER applying — this is what the control plane times.
      ws.send(JSON.stringify({ type: 'applied', name: msg.flag.name, version: msg.flag.version }));
    }
  });

  ws.on('close', retry);
  ws.on('error', () => ws.close());

  let retried = false;
  function retry() {
    if (retried) return;
    retried = true;
    if (status === 'live') status = 'stale'; // keep serving the cache
    urlIndex += 1; // rotate to the fallback URL
    setTimeout(connect, 2000);
  }
}

// Our own IPv4 addresses: UpCloud's private SDN range is 10.x, everything
// else non-internal is the public interface.
function myIps() {
  const ips = {};
  for (const iface of Object.values(os.networkInterfaces())) {
    for (const addr of iface ?? []) {
      if (addr.family !== 'IPv4' || addr.internal) continue;
      if (addr.address.startsWith('10.')) ips.private ??= addr.address;
      else ips.public ??= addr.address;
    }
  }
  return ips;
}

// ---------------------------------------------------------------------------
// Percentage rollouts: hash(flag + unit) -> stable bucket 0-99. The same
// unit (user id, session, tile id) always lands in the same bucket, so a
// 30% rollout is sticky per user instead of flickering per request.
// Must match sdk/ripple-client.js.
// ---------------------------------------------------------------------------
function bucket(flagName, unit) {
  let h = 0x811c9dc5; // FNV-1a
  const s = `${flagName}:${unit}`;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h % 100;
}

function evaluate(flag, unit) {
  if (!flag.enabled) return false;
  if (flag.rollout >= 100) return true;
  return bucket(flag.name, unit ?? 'anonymous') < flag.rollout;
}

// ---------------------------------------------------------------------------
// Local read API — what app SDKs hit. Sub-millisecond by construction.
// ---------------------------------------------------------------------------
const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const json = (code, data) => {
    res.writeHead(code, { 'content-type': 'application/json', 'access-control-allow-origin': '*' });
    res.end(JSON.stringify(data));
  };

  if (url.pathname === '/flags') {
    return json(200, { zone: ZONE, status, flags: [...flags.values()] });
  }

  const m = url.pathname.match(/^\/flags\/([\w-]+)$/);
  if (m) {
    const flag = flags.get(m[1]);
    if (!flag) return json(404, { error: `no flag "${m[1]}"` });
    const unit = url.searchParams.get('unit');
    return json(200, { name: flag.name, enabled: evaluate(flag, unit), version: flag.version, zone: ZONE, status });
  }

  json(404, { error: 'not found' });
});

server.listen(PORT, () => console.log(`[${ZONE}] edge serving flags on :${PORT}`));
connect();
