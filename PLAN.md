# Port Plan — OPNsense Widget for Omarchy Linux

This document is the design/implementation plan for porting the Windows
[OPNsense Widget](https://github.com/iainlennox/opensense-widget) (WPF/.NET 10)
to a Quickshell shell plugin that runs natively on **Omarchy** (Arch +
Hyprland + Quickshell).

Status: **v0.1 — working plugin** (floating panel + optional bar toggle,
settings form, live polling).

---

## 1. Goal

Recreate the Windows widget's behaviour on a Wayland desktop: a small, dark,
always-available monitor that watches OPNsense firewall interfaces in real
time, plus optional server pings and Plex/DNS service checks — without
requiring Windows, .NET, or a system tray.

The original app sits in the Windows system tray and shows a compact window.
On Omarchy the closest primitives are:

- **Floating layer-shell widget** (a Quickshell `PanelWindow`) for the always-
  visible monitor window.
- **Bar icon** (`BarWidget`) as the tray-like toggle.

## 2. Source app analysis

From `iainlennox/opensense-widget` (read from the repo):

| Concern | Source | Notes |
|---------|--------|-------|
| OPNsense interfaces | `OpnsenseApiClient` → `GET /api/interfaces/overview/interfacesInfo` | Basic auth `key:secret`, self-signed cert ignored |
| Traffic counters | `GET /api/diagnostics/traffic/interface` | `bytes received` / `bytes transmitted` |
| Bandwidth rate | `MainWindow.PollBandwidthAsync` | `delta_bytes * 8 / delta_time`, EMA-smoothed |
| Sparkline | `InterfaceDisplay` (WPF Path geometry) | 60s window, scale = max*1.1 |
| Latency | API round-trip time (`OverviewLatency`, `TrafficLatency`) | smoothed average |
| Packet loss | ratio of failed API polls | `failCount / sampleCount` |
| Utilisation | `(in+out)bps / linkSpeedBps` | from `media` field |
| Health score | `InterfaceDisplay.RecalculateHealth` | latency/loss/util thresholds → Excellent/Good/Fair/Poor |
| Servers | `PingAllServersAsync` (ICMP) | hostname, OS badge, latency, resolved IP |
| Services | `PlexServiceClient` + `CheckDnsServiceAsync` | Plex `/identity` + `/status/sessions`; DNS UDP query |
| Internet | `PingGoogleAsync` → 8.8.8.8 | reachable + latency |
| Config | `ConfigManager` (`AppConfig`) | `%LocalAppData%/OpnsenseWidget/config.json` |
| Notifications | `NotificationService` (tray balloon) | interface up/down, latency threshold, server/service state |

## 3. Target platform

Omarchy's shell (`omarchy-shell`) is a long-running Quickshell process. Shell
plugins live in `~/.config/omarchy/plugins/<plugin-id>/` and declare a
`manifest.json`:

```json
{
  "schemaVersion": 1,
  "id": "opensense-widget",
  "name": "OPNsense Widget",
  "kinds": ["panel", "bar-widget"],
  "keepLoaded": true,
  "entryPoints": { "panel": "Panel.qml", "barWidget": "BarWidget.qml" }
}
```

Key contract points (from `shell.qml` + `PluginRegistry.qml`):

- `kinds` decides how the shell mounts it. `panel` plugins are loaded on
  demand via `summon`; `keepLoaded: true` keeps the panel mounted so it can
  stay visible without being summoned.
- Third-party plugin ids **must not** start with `omarchy.` (reserved).
- To enable a non-bar plugin it must appear in `shell.json` `plugins[]`.
- A bar widget must appear in `bar.layout.*` to show on the bar.
- The panel entry point is an `Item`; the shell injects `manifest`
  (`__sourceDir` gives the plugin folder) and optionally `service`.

## 4. Architecture mapping

| Windows concept | Omarchy equivalent |
|-----------------|--------------------|
| WPF `Window` (compact, auto-height) | `PanelWindow` (layer-shell, anchored bottom-right, auto-height) |
| System tray `TaskbarIcon` | Optional `BarWidget` bar icon that toggles the panel |
| `DispatcherTimer` poll loops | QML `Timer` + `Quickshell.Io.Process` |
| `HttpClient` + Basic auth | `opensense-status.py` using `urllib` (unverified TLS) |
| `System.Net.NetworkInformation.Ping` | `ping -c 1 -W n host` (iputils) |
| WPF geometry Path for sparkline | `Canvas` drawing a polyline |
| `AppConfig` JSON at `%LocalAppData%` | `config.json` at `~/.config/omarchy/opensense-widget/` |
| `INotifyPropertyChanged` | QML `QtObject` properties / reassigned JS arrays |
| Balloon notifications | `notify-send` via `Quickshell.execDetached` |

### Component responsibilities

- **`Panel.qml`** — the floating window, the poll timers, the merge logic
  (bandwidth deltas, sparkline history, health), and the settings form.
- **`BarWidget.qml`** — a single bar glyph that calls `bar.shell.toggle`.
- **`Model.js`** — pure, Node-testable logic (no QML): bandwidth/uptime/link-
  speed formatting, health scoring, colour selection, sparkline point math.
- **`config.js`** — pure config model: defaults, parse, serialise, normalise,
  `getOrCreateInterface`.
- **`opensense-status.py`** — a small gatherer run as a subprocess; it does all
  network I/O (OPNsense API, ICMP, Plex, DNS) and emits one JSON object per
  subcommand. Keeping network work out of QML keeps the UI responsive and the
  logic testable.

### Data flow

```
Timer (refreshMs / 30s / 60s / 10s)
        │
        └─> Process: opensense-status.py <subcommand> --config <path>
                  │  (single JSON line on stdout)
                  ▼
             SplitParser / StdioCollector -> applyX(text)
                  │
                  ▼
             Panel.qml parses + merges
                  │
                  ├─ interfaces: bandwidth delta + sparkline history + health
                  ├─ servers: online / latency / ip
                  ├─ services: online / detail
                  └─ internet: reachable / latency
                  ▼
             root.interfaces / servers / services (reassigned arrays)
                  ▼
             Repeater delegates -> cards/rows -> Canvas sparklines
```

### Poll cadence

| Data | Cadence | Source |
|------|---------|--------|
| Interfaces + traffic | `refreshInterval` (default 5 s) | OPNsense API |
| Servers | 30 s | ICMP |
| Services | 60 s | Plex / DNS |
| Internet | 10 s | ICMP 8.8.8.8 |

## 5. Feature parity

| Windows feature | Ported? | Notes |
|-----------------|---------|-------|
| Real-time interface monitoring | ✅ | `interfaces` subcommand |
| Traffic rate + sparkline | ✅ | in/out sparkline per interface |
| Link speed formatting | ✅ | `Model.displaySpeed` |
| Health scoring | ✅ | `Model.healthStatus` |
| WAN detection | ✅ | `Model.isWan` |
| Show/hide interfaces | ✅ (hidden via config) | expand/collapse per card |
| Reorder interfaces | 🔶 | config `order`; UI reorder not yet wired |
| Rename interfaces | 🔶 | config `customName`; inline rename not yet wired |
| Blur IP | 🔶 | config flag stored; not applied to display yet |
| Server ping monitor | ✅ | online + latency + OS badge |
| Plex monitor | ✅ | version + active stream count/detail |
| DNS monitor | ✅ | NOERROR/NXDOMAIN/SERVFAIL + TTL |
| Internet reachability | ✅ | footer |
| Notifications | ✅ | interface up/down via `notify-send` |
| Tray show/hide | ✅ | bar icon toggle |
| Remember window position | 🔶 | fixed bottom-right anchor for now |
| Config export/import | 🔶 | not yet |
| Settings UI | ✅ | gear → settings form |

Legend: ✅ done · 🔶 partial / roadmap

## 6. Implementation notes

### QML reactivity

The interface display objects are created as `QtObject`s (via a `Component`
factory) rather than plain JS objects. Mutating a `QtObject` property (e.g.
`iface.isExpanded = !iface.isExpanded` on click) notifies QML bindings, so
cards collapse/expand and sparklines repaint. Servers/services are rebuilt as
fresh plain objects each poll and the array is reassigned, which also triggers
Repeater re-evaluation.

### Bandwidth smoothing

`opensense-status.py` returns raw byte counters. `Panel.qml` keeps
`prevTraffic[name]` and `prevTrafficTime`; each poll computes
`(rxDelta * 8 / elapsed)`. History is stored per interface as
`{value, time}` samples pruned to a 60-second window; the sparkline scale is
`max(peak * 1.1, 1.0)`.

### Config

`~/.config/omarchy/opensense-widget/config.json`:

```json
{
  "baseUrl": "https://192.168.1.1",
  "apiKey": "",
  "apiSecret": "",
  "refreshIntervalSeconds": 5,
  "blurIpAddress": false,
  "interfaces": [{ "deviceName": "wan", "customName": null, "isHidden": false, "order": 0 }],
  "servers": [{ "hostname": "server1", "customName": null, "description": null, "operatingSystem": "Linux", "order": 0 }],
  "services": [{ "serviceType": "Plex", "hostname": "192.168.1.10", "customName": null, "token": null, "order": 0 }]
}
```

Read with a `FileView` (`watchChanges`), written with a `Process` that pipes
the serialised JSON to `cat > file`.

## 7. Verification

```bash
# Pure-logic unit checks (Node)
node -e 'const M=require("./Model.js"); console.log(M.formatBandwidth(1_500_000_000))'   # 1.5 Gbps
node -e 'const C=require("./config.js"); console.log(C.parse("{}").refreshIntervalSeconds)'

# Gatherer smoke test (no live OPNsense needed; failures handled gracefully)
python3 opensense-status.py servers --config /tmp/test.json
python3 opensense-status.py interfaces --config /tmp/test.json

# QML type check (note: some Quickshell/qs.* warnings are expected false positives)
qmllint -I /usr/lib/qt6/qml -I <qs-import-path> Panel.qml

# Live: install and watch the shell pick it up
./install.sh --bar
```

## 8. Roadmap

- [x] Manifest + panel/bar-widget structure
- [x] `opensense-status.py` gatherer (OPNsense, ping, Plex, DNS, internet)
- [x] `Model.js` + `config.js` pure logic
- [x] `Panel.qml` floating widget, settings form, live polling
- [x] `BarWidget.qml` toggle
- [x] `install.sh` / `uninstall.sh`
- [ ] Inline interface rename (pencil) and drag-free up/down reorder
- [ ] Apply `blurIpAddress` to the display
- [ ] Remember/allow moving the widget position
- [ ] Export/import config
- [ ] Latency threshold notifications (>=100 ms)
- [ ] Screenshot preview for README
- [ ] More service types (e.g. custom HTTP health checks)

## 9. Author

**Iain Lennox** — Lennox Technology

*Made with ❤️ in Scotland*
