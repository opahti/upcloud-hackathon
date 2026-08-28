// Ripple control plane: owns the flags, pushes changes to edges over
// WebSocket, measures propagation per zone, and serves the Wall UI.
//
// Propagation measurement is deliberately clock-skew-proof: we stamp t0 when
// we SEND an update and stop the clock when the edge's ack ARRIVES back here.
// Both timestamps come from this machine's clock. The number therefore
// includes the ack's return trip — an honest upper bound.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';

const PORT = Number(process.env.PORT || 4000);
const ZONE = process.env.ZONE || 'local';
const DIR = path.dirname(fileURLToPath(import.meta.url));
const STATE_FILE = path.join(DIR, 'flags.json');

// ---------------------------------------------------------------------------
// Flag store. File-backed for now; swapping persist()/load() for Managed
// PostgreSQL is the enable_postgres day-2 task.
// ---------------------------------------------------------------------------
const flags = new Map(); // name -> { name, enabled, rollout, version, updatedAt }

// Seeds are merged on every boot: existing flags keep their state, missing
// ones get created — so adding a seed here shows up on a redeploy without
// wiping the demo's flag history.
const SEED_FLAGS = {
  // product-style flags (what a real team would gate)
  new_checkout: { enabled: true, rollout: 25 },
  beta_search: { enabled: true, rollout: 10 },
  maintenance_banner: { enabled: false, rollout: 100 },
  // flags that visibly drive the wall itself
  party_mode: { enabled: false, rollout: 100 },
  dark_mode: { enabled: true, rollout: 100 },
  turbo_spin: { enabled: false, rollout: 100 },
  show_labels: { enabled: true, rollout: 100 },
};

function load() {
  if (fs.existsSync(STATE_FILE)) {
    for (const f of JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'))) flags.set(f.name, f);
  }
  for (const [name, init] of Object.entries(SEED_FLAGS)) {
    if (!flags.has(name)) upsertFlag(name, init);
  }
}

function persist() {
  fs.writeFileSync(STATE_FILE, JSON.stringify([...flags.values()], null, 2));
}

const pendingFlips = new Map(); // "name@version" -> t0 (ms)

function upsertFlag(name, patch) {
  const f = flags.get(name) ?? { name, enabled: false, rollout: 100, version: 0 };
  Object.assign(f, patch);
  f.version += 1;
  f.updatedAt = new Date().toISOString();
  flags.set(name, f);
  persist();

  pendingFlips.set(`${name}@${f.version}`, Date.now());
  setTimeout(() => pendingFlips.delete(`${name}@${f.version}`), 60_000);

  broadcast(edgeSockets.keys(), { type: 'update', flag: f });
  broadcast(wallSockets, { type: 'flag', flag: f });
  return f;
}

// ---------------------------------------------------------------------------
// WebSocket plumbing: /ws/edge for edge nodes, /ws/wall for dashboards.
// ---------------------------------------------------------------------------
const edgeSockets = new Map(); // ws -> { zone, connectedAt }
const wallSockets = new Set();

function broadcast(sockets, msg) {
  const data = JSON.stringify(msg);
  for (const ws of sockets) if (ws.readyState === ws.OPEN) ws.send(data);
}

function edgeList() {
  return [...edgeSockets.values()].map((e) => ({ zone: e.zone, connectedAt: e.connectedAt, transport: e.transport, ips: e.ips }));
}

const wssEdge = new WebSocketServer({ noServer: true });
const wssWall = new WebSocketServer({ noServer: true });

wssEdge.on('connection', (ws) => {
  ws.on('message', (raw) => {
    let msg;
    try { msg = JSON.parse(raw); } catch { return; }

    if (msg.type === 'hello') {
      // Private SDN addresses live in 10.x; anything else came over the internet.
      const transport = /\/\/10\./.test(msg.via ?? '') ? 'sdn' : 'public';
      edgeSockets.set(ws, { zone: msg.zone, connectedAt: new Date().toISOString(), transport, ips: msg.ips ?? {} });
      ws.send(JSON.stringify({ type: 'snapshot', flags: [...flags.values()] }));
      broadcast(wallSockets, { type: 'edges', edges: edgeList() });
      console.log(`edge connected: ${msg.zone}`);
    }

    if (msg.type === 'applied') {
      const t0 = pendingFlips.get(`${msg.name}@${msg.version}`);
      const edge = edgeSockets.get(ws);
      if (t0 && edge) {
        broadcast(wallSockets, {
          type: 'propagation',
          zone: edge.zone,
          flag: flags.get(msg.name),
          ms: Date.now() - t0,
        });
      }
    }
  });

  ws.on('close', () => {
    const edge = edgeSockets.get(ws);
    edgeSockets.delete(ws);
    if (edge) {
      console.log(`edge disconnected: ${edge.zone}`);
      broadcast(wallSockets, { type: 'edges', edges: edgeList() });
    }
  });
});

wssWall.on('connection', (ws) => {
  wallSockets.add(ws);
  ws.send(JSON.stringify({ type: 'snapshot', flags: [...flags.values()], edges: edgeList(), controlZone: ZONE }));
  ws.on('close', () => wallSockets.delete(ws));
});

// ---------------------------------------------------------------------------
// HTTP: a tiny REST API + static files for the Wall.
// ---------------------------------------------------------------------------
async function readBody(req) {
  let body = '';
  for await (const chunk of req) body += chunk;
  return body ? JSON.parse(body) : {};
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const json = (code, data) => {
    res.writeHead(code, { 'content-type': 'application/json' });
    res.end(JSON.stringify(data));
  };

  try {
    if (url.pathname === '/api/flags' && req.method === 'GET') {
      return json(200, [...flags.values()]);
    }

    const flagMatch = url.pathname.match(/^\/api\/flags\/([\w-]+)$/);
    if (flagMatch && req.method === 'PUT') {
      const { enabled, rollout } = await readBody(req);
      const patch = {};
      if (typeof enabled === 'boolean') patch.enabled = enabled;
      if (Number.isInteger(rollout) && rollout >= 0 && rollout <= 100) patch.rollout = rollout;
      return json(200, upsertFlag(flagMatch[1], patch));
    }

    if (req.method === 'GET') {
      const publicDir = path.join(DIR, 'public');
      const rel = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
      const file = path.join(publicDir, path.normalize(rel));
      if (file.startsWith(publicDir) && fs.existsSync(file) && fs.statSync(file).isFile()) {
        const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json' };
        res.writeHead(200, { 'content-type': types[path.extname(file)] || 'application/octet-stream' });
        return res.end(fs.readFileSync(file));
      }
    }

    json(404, { error: 'not found' });
  } catch (err) {
    json(500, { error: String(err) });
  }
});

server.on('upgrade', (req, socket, head) => {
  const { pathname } = new URL(req.url, `http://${req.headers.host}`);
  const wss = pathname === '/ws/edge' ? wssEdge : pathname === '/ws/wall' ? wssWall : null;
  if (!wss) return socket.destroy();
  wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws, req));
});

load();
server.listen(PORT, () => console.log(`ripple control plane on :${PORT}`));
