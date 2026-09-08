// Model.js — pure logic for the OPNsense Widget, ported from the original
// Windows/WPF app (InterfaceDisplay.cs, MainWindow.xaml.cs).
//
// Every function is declared at the top level so it is exposed directly to a
// QML `import "Model.js" as Model`. The `module.exports` at the bottom is only
// for Node-based unit tests; QML ignores it.

// ---- health thresholds (green -> amber -> red) --------------------------
var LATENCY_GREEN_MS = 50;
var LATENCY_AMBER_MS = 200;
var PACKET_LOSS_GREEN_PCT = 0;
var PACKET_LOSS_AMBER_PCT = 5;
var UTILIZATION_GREEN_PCT = 50;
var UTILIZATION_AMBER_PCT = 80;

function clamp(v, lo, hi) {
  return Math.max(lo, Math.min(hi, v));
}

// Format a raw bits/second figure into a human string (bps / Kbps / Mbps /
// Gbps). Mirrors InterfaceDisplay.FormatBandwidth.
function formatBandwidth(bps) {
  if (!isFinite(bps) || bps < 0) bps = 0;
  if (bps >= 1000000000) return (bps / 1000000000.0).toFixed(1) + " Gbps";
  if (bps >= 1000000) return (bps / 1000000.0).toFixed(1) + " Mbps";
  if (bps >= 1000) return Math.round(bps / 1000.0) + " Kbps";
  return Math.round(bps) + " bps";
}

// Parse a formatted bandwidth string ("12.5 Mbps") back to bps.
function parseBandwidthToBps(str) {
  if (!str) return 0;
  var parts = String(str).trim().split(/\s+/);
  if (parts.length < 2) return 0;
  var val = parseFloat(parts[0]);
  if (!isFinite(val)) return 0;
  var unit = String(parts[1]).toLowerCase();
  if (unit.indexOf("gbps") === 0) return val * 1000000000;
  if (unit.indexOf("mbps") === 0) return val * 1000000;
  if (unit.indexOf("kbps") === 0) return val * 1000;
  return val;
}

// Parse an OPNsense `media` string ("1000baseT", "2500baseX", "10G") into a
// bits/second number. "1000baseT" is 1000 Mbit/s, so base-* strings are
// interpreted as Mbps (an improvement over the original C#, which read them
// as raw bps).
function parseLinkSpeedBps(media) {
  if (!media) return 0;
  var m = /^\s*(\d+(?:\.\d+)?)\s*([A-Za-z]?)/.exec(String(media));
  if (!m) return 0;
  var speed = parseFloat(m[1]);
  var suffix = (m[2] || "").toUpperCase();
  if (suffix === "G") return speed * 1000000000;
  if (suffix === "M") return speed * 1000000;
  if (suffix === "K") return speed * 1000;
  if (/base/i.test(String(media))) return speed * 1000000;
  return speed;
}

// Display a link speed as "N Gbps" / "N Mbps" / "N Kbps" from raw media.
function displaySpeed(media) {
  var bps = parseLinkSpeedBps(media);
  if (!bps) return media || "";
  return formatBandwidth(bps);
}

// Format an OPNsense `uptime` string ("3 days, 02:14:22" or "02:14:22")
// into a compact "3d 2h" / "2h 14m" / "14s". Mirrors FormatUptime.
function formatUptime(raw) {
  if (!raw) return "";
  var s = String(raw).trim().toLowerCase();
  var totalSeconds = 0;

  if (s.indexOf("day") !== -1) {
    var parts = s.split(/\s+/);
    for (var i = 0; i < parts.length - 1; i++) {
      if (parts[i + 1].indexOf("day") === 0 && isFinite(parseFloat(parts[i])))
        totalSeconds += parseFloat(parts[i]) * 86400;
    }
    var commaParts = s.split(",");
    var timePart = commaParts.length > 1 ? commaParts[commaParts.length - 1].trim() : "";
    if (timePart === "") timePart = parts[parts.length - 1] || "";
    totalSeconds += parseClock(timePart);
  } else if (s.indexOf(":") !== -1) {
    totalSeconds += parseClock(s);
  }

  if (totalSeconds <= 0) return raw;
  var days = Math.floor(totalSeconds / 86400);
  var hours = Math.floor((totalSeconds % 86400) / 3600);
  if (days > 0 && hours > 0) return days + "d " + hours + "h";
  if (days > 0) return days + "d";
  if (hours > 0) {
    var mins = Math.floor((totalSeconds % 3600) / 60);
    return mins > 0 ? hours + "h " + mins + "m" : hours + "h";
  }
  return Math.floor(totalSeconds % 60) + "s";
}

function parseClock(str) {
  var parts = String(str).split(":");
  var total = 0;
  if (parts.length === 3) {
    var h = parseInt(parts[0], 10), m = parseInt(parts[1], 10), sec = parseInt(parts[2], 10);
    if (isFinite(h)) total += h * 3600;
    if (isFinite(m)) total += m * 60;
    if (isFinite(sec)) total += sec;
  }
  return total;
}

function isWan(name, description, customName) {
  var n = String(name || "").toLowerCase();
  var d = String(description || "").toLowerCase();
  var c = String(customName || "").toLowerCase();
  return n.indexOf("wan") !== -1 || d.indexOf("wan") !== -1 ||
         n.indexOf("pppoe") !== -1 || d.indexOf("pppoe") !== -1 ||
         n.indexOf("vwan") !== -1 || d.indexOf("vwan") !== -1 ||
         c.indexOf("wan") !== -1;
}

function latencyColor(isUp, ms) {
  if (!isUp || !(ms > 0)) return "#6c7086";
  if (ms < LATENCY_GREEN_MS) return "#a6e3a1";
  if (ms < LATENCY_AMBER_MS) return "#f9e2af";
  return "#f38ba8";
}

function packetLossColor(isUp, pct) {
  if (!isUp || !(pct > 0)) return "#6c7086";
  if (pct < PACKET_LOSS_AMBER_PCT) return "#f9e2af";
  return "#f38ba8";
}

function utilizationColor(isUp, pct) {
  if (!isUp || !(pct > 0)) return "#6c7086";
  if (pct < UTILIZATION_GREEN_PCT) return "#a6e3a1";
  if (pct < UTILIZATION_AMBER_PCT) return "#f9e2af";
  return "#f38ba8";
}

// RecalculateHealth: score from latency, packet loss and utilisation.
function healthStatus(isUp, latencyMs, packetLossPct, utilizationPct) {
  if (!isUp) return "Offline";
  var score = 100.0;

  if (latencyMs > 0) {
    if (latencyMs >= 200) score -= 30;
    else if (latencyMs >= 80) score -= 15;
    else if (latencyMs >= 30) score -= 5;
  }
  if (packetLossPct > 0) {
    if (packetLossPct >= 10) score -= 40;
    else if (packetLossPct >= 3) score -= 20;
    else if (packetLossPct >= 1) score -= 10;
  }
  if (utilizationPct > 0) {
    if (utilizationPct >= 90) score -= 20;
    else if (utilizationPct >= 70) score -= 10;
    else if (utilizationPct >= 40) score -= 3;
  }
  if (score >= 85) return "Excellent";
  if (score >= 65) return "Good";
  if (score >= 40) return "Fair";
  return "Poor";
}

function healthColor(status) {
  switch (status) {
    case "Excellent": return "#a6e3a1";
    case "Good": return "#89b4fa";
    case "Fair": return "#f9e2af";
    case "Poor": return "#f38ba8";
    default: return "#6c7086";
  }
}

function healthIcon(status) {
  switch (status) {
    case "Excellent": return "\u25CF"; // ●
    case "Good": return "\u25C6";      // ◆
    case "Fair": return "\u25B2";      // ▲
    case "Poor": return "\u25A0";      // ■
    default: return "\u25CB";          // ○
  }
}

// ---- sparkline ---------------------------------------------------------
// Build a normalized polyline in a 0..1 x 0..1 space from (value, ageSeconds)
// samples. Returns a list of [x, y] points (newest at x=1, oldest at x=0).
function sparklinePoints(samples, scale) {
  var points = [];
  if (!samples || samples.length < 2 || !(scale > 0)) return points;
  var now = Date.now() / 1000;
  var windowSeconds = 60;
  for (var i = 0; i < samples.length; i++) {
    var s = samples[i];
    var age = now - s.time;
    var x = 1.0 - (age / windowSeconds);
    if (x < 0) continue;
    var normalized = Math.min(1.0, s.value / scale);
    var y = 1.0 - (normalized * 0.88) - 0.06;
    points.push([x, y]);
  }
  return points;
}

function sparklineMax(samples) {
  var max = 0;
  for (var i = 0; i < samples.length; i++)
    if (samples[i].value > max) max = samples[i].value;
  return max;
}

function seedScale(samples) {
  var max = sparklineMax(samples);
  return Math.max(max * 1.1, 1.0);
}

// CommonJS export for Node-based unit tests. QML imports expose the
// top-level functions above directly.
if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    LATENCY_GREEN_MS: LATENCY_GREEN_MS,
    LATENCY_AMBER_MS: LATENCY_AMBER_MS,
    PACKET_LOSS_GREEN_PCT: PACKET_LOSS_GREEN_PCT,
    PACKET_LOSS_AMBER_PCT: PACKET_LOSS_AMBER_PCT,
    UTILIZATION_GREEN_PCT: UTILIZATION_GREEN_PCT,
    UTILIZATION_AMBER_PCT: UTILIZATION_AMBER_PCT,
    formatBandwidth: formatBandwidth,
    parseBandwidthToBps: parseBandwidthToBps,
    parseLinkSpeedBps: parseLinkSpeedBps,
    displaySpeed: displaySpeed,
    formatUptime: formatUptime,
    isWan: isWan,
    latencyColor: latencyColor,
    packetLossColor: packetLossColor,
    utilizationColor: utilizationColor,
    healthStatus: healthStatus,
    healthColor: healthColor,
    healthIcon: healthIcon,
    sparklinePoints: sparklinePoints,
    sparklineMax: sparklineMax,
    seedScale: seedScale
  };
}
