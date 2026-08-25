// The deliberately tiny Ripple SDK. An app points it at its NEAREST edge
// node and reads flags locally. Keep it this small — the wall is the
// product; SDK scope creep is where the weekend goes to die.
//
//   import { RippleClient } from './ripple-client.js';
//   const flags = new RippleClient('http://<edge-ip>:4100', { unit: userId });
//   if (await flags.get('new_checkout')) { ... }

export class RippleClient {
  constructor(edgeUrl, { unit = 'anonymous', refreshMs = 2000 } = {}) {
    this.edgeUrl = edgeUrl.replace(/\/$/, '');
    this.unit = unit;
    this.cache = new Map(); // name -> { enabled, fetchedAt }
    this.refreshMs = refreshMs;
  }

  async get(name, fallback = false) {
    const hit = this.cache.get(name);
    if (hit && Date.now() - hit.fetchedAt < this.refreshMs) return hit.enabled;
    try {
      const res = await fetch(`${this.edgeUrl}/flags/${name}?unit=${encodeURIComponent(this.unit)}`);
      if (!res.ok) return hit?.enabled ?? fallback;
      const { enabled } = await res.json();
      this.cache.set(name, { enabled, fetchedAt: Date.now() });
      return enabled;
    } catch {
      // Edge unreachable: last known value beats an exception, every time.
      return hit?.enabled ?? fallback;
    }
  }
}
