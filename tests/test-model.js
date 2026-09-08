// Pure-logic tests for Model.js and config.js. Run with: node tests/test-model.js
const assert = require("assert");
const Model = require("../Model.js");
const Config = require("../config.js");

// ---- Model ----
assert.strictEqual(Model.formatBandwidth(1_500_000_000), "1.5 Gbps");
assert.strictEqual(Model.formatBandwidth(100_000_000), "100.0 Mbps");
assert.strictEqual(Model.formatBandwidth(12_000), "12 Kbps");
assert.strictEqual(Model.formatBandwidth(900), "900 bps");

assert.strictEqual(Model.parseLinkSpeedBps("1000baseT"), 1_000_000_000);
assert.strictEqual(Model.parseLinkSpeedBps("100M"), 100_000_000);
assert.strictEqual(Model.parseLinkSpeedBps("10G"), 10_000_000_000);

assert.strictEqual(Model.formatUptime("3 days, 02:14:22"), "3d 2h");
assert.strictEqual(Model.formatUptime("02:14:22"), "2h 14m");
assert.strictEqual(Model.formatUptime("0 days, 00:00:45"), "45s");

assert.strictEqual(Model.isWan("wan", "WAN Interface", ""), true);
assert.strictEqual(Model.isWan("lan", "LAN", ""), false);
assert.strictEqual(Model.isWan("pppoe0", "", "Internet"), true);

assert.strictEqual(Model.healthStatus(true, 10, 0, 10), "Excellent");
assert.strictEqual(Model.healthStatus(true, 250, 0, 10), "Good");
assert.strictEqual(Model.healthStatus(true, 250, 40, 10), "Poor");
assert.strictEqual(Model.healthStatus(false, 0, 0, 0), "Offline");

assert.strictEqual(Model.healthColor("Excellent"), "#a6e3a1");
assert.strictEqual(Model.healthColor("Poor"), "#f38ba8");

// sparkline: newest sample is at the right edge, oldest at the left
const now = Date.now() / 1000;
const pts = Model.sparklinePoints([
  { value: 100, time: now - 55 },
  { value: 200, time: now - 1 }
], 1000);
assert.strictEqual(pts.length, 2);
assert.ok(pts[1][0] > 0.9, "newest sample near right edge, got " + pts[1][0]);
assert.ok(pts[0][0] < 0.2, "oldest sample near left edge, got " + pts[0][0]);

// ---- Config ----
const cfg = Config.parse(JSON.stringify({
  baseUrl: "https://x", apiKey: "k", apiSecret: "s",
  refreshIntervalSeconds: 7,
  interfaces: [{ deviceName: "wan", customName: "WAN", order: 1 }],
  servers: [{ hostname: "srv", operatingSystem: "Linux" }],
  services: [{ serviceType: "Plex", hostname: "p" }]
}));
assert.strictEqual(cfg.baseUrl, "https://x");
assert.strictEqual(cfg.refreshIntervalSeconds, 7);
assert.strictEqual(cfg.interfaces[0].deviceName, "wan");
assert.strictEqual(cfg.servers[0].operatingSystem, "Linux");
assert.strictEqual(Config.isConfigured(cfg), true);
assert.strictEqual(Config.isConfigured(Config.defaultConfig()), false);

const got = Config.getOrCreateInterface(cfg, "lan");
assert.strictEqual(got.deviceName, "lan");
assert.strictEqual(cfg.interfaces.length, 2);

console.log("All tests passed.");
