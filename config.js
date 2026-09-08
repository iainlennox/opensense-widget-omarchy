// config.js — config model for the OPNsense Widget.
//
// Pure functions only: parse/serialize a config object that mirrors the
// original Windows app's AppConfig. File I/O lives in QML (FileView for
// reads, a Process for writes); this module never touches the filesystem.
//
// Functions are declared at the top level so QML `import "config.js" as
// Config` exposes them directly. The `module.exports` at the bottom is only
// for Node-based unit tests.

function clone(obj) {
  return JSON.parse(JSON.stringify(obj));
}

function defaultConfig() {
  return {
    baseUrl: "https://192.168.1.1",
    apiKey: "",
    apiSecret: "",
    refreshIntervalSeconds: 5,
    blurIpAddress: false,
    interfaces: [],
    servers: [],
    services: []
  };
}

function normalize(raw) {
  var cfg = defaultConfig();
  if (raw && typeof raw === "object") {
    if (typeof raw.baseUrl === "string") cfg.baseUrl = raw.baseUrl;
    if (typeof raw.apiKey === "string") cfg.apiKey = raw.apiKey;
    if (typeof raw.apiSecret === "string") cfg.apiSecret = raw.apiSecret;
    if (typeof raw.refreshIntervalSeconds === "number" && raw.refreshIntervalSeconds > 0)
      cfg.refreshIntervalSeconds = raw.refreshIntervalSeconds;
    if (typeof raw.blurIpAddress === "boolean") cfg.blurIpAddress = raw.blurIpAddress;
    if (Array.isArray(raw.interfaces)) cfg.interfaces = raw.interfaces.map(normalizeInterface);
    if (Array.isArray(raw.servers)) cfg.servers = raw.servers.map(normalizeServer);
    if (Array.isArray(raw.services)) cfg.services = raw.services.map(normalizeService);
  }
  return cfg;
}

function normalizeInterface(i) {
  var out = { deviceName: "", customName: null, isHidden: false, order: 0 };
  if (!i) return out;
  if (typeof i.deviceName === "string") out.deviceName = i.deviceName;
  if (typeof i.customName === "string") out.customName = i.customName || null;
  if (typeof i.isHidden === "boolean") out.isHidden = i.isHidden;
  if (typeof i.order === "number") out.order = i.order;
  return out;
}

function normalizeServer(s) {
  var out = { hostname: "", customName: null, description: null, operatingSystem: "Windows Server", order: 0 };
  if (!s) return out;
  if (typeof s.hostname === "string") out.hostname = s.hostname;
  if (typeof s.customName === "string") out.customName = s.customName || null;
  if (typeof s.description === "string") out.description = s.description || null;
  if (typeof s.operatingSystem === "string" && s.operatingSystem !== "")
    out.operatingSystem = s.operatingSystem;
  if (typeof s.order === "number") out.order = s.order;
  return out;
}

function normalizeService(s) {
  var out = { serviceType: "Plex", hostname: "", customName: null, token: null, order: 0 };
  if (!s) return out;
  if (typeof s.serviceType === "string" && s.serviceType !== "") out.serviceType = s.serviceType;
  if (typeof s.hostname === "string") out.hostname = s.hostname;
  if (typeof s.customName === "string") out.customName = s.customName || null;
  if (typeof s.token === "string") out.token = s.token || null;
  if (typeof s.order === "number") out.order = s.order;
  return out;
}

function parse(jsonText) {
  if (!jsonText) return defaultConfig();
  var raw = null;
  try { raw = JSON.parse(jsonText); } catch (e) { return defaultConfig(); }
  return normalize(raw);
}

function serialize(config) {
  return JSON.stringify(config, null, 2);
}

function isConfigured(config) {
  return !!config && !!config.baseUrl && !!config.apiKey && !!config.apiSecret;
}

function getOrCreateInterface(config, deviceName) {
  var list = config.interfaces;
  for (var i = 0; i < list.length; i++)
    if (list[i].deviceName === deviceName) return list[i];
  var entry = { deviceName: deviceName, customName: null, isHidden: false, order: list.length };
  list.push(entry);
  return entry;
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    clone: clone,
    defaultConfig: defaultConfig,
    normalize: normalize,
    parse: parse,
    serialize: serialize,
    isConfigured: isConfigured,
    getOrCreateInterface: getOrCreateInterface
  };
}
