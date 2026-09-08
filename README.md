# OPNsense Widget (Omarchy)

A floating desktop widget for [Omarchy](https://omarchy.org/) Linux that monitors
OPNsense firewall interfaces in real time. It is a Quickshell shell plugin —
the Linux/Omarchy port of the Windows app at
[iainlennox/opensense-widget](https://github.com/iainlennox/opensense-widget).

The widget floats over the desktop and shows, per interface: link status,
IP, MAC, link speed, uptime, latency, packet loss, utilisation and a live
bandwidth sparkline. It also pings configured servers and polls services
(Plex sessions, DNS resolution), and shows a combined health footer.

## Features

- Real-time interface monitoring via the OPNsense API
- Live bandwidth sparklines (in/out) with smoothing
- Link speed auto-formatting (`1 Gbps`, `100 Mbps`, …)
- Health scoring per interface (Excellent / Good / Fair / Poor)
- WAN detection and an overall worst-health footer
- Server ping monitor (ICMP, online/offline + latency)
- Service monitor: Plex (`/identity`, `/status/sessions`) and DNS (UDP 53)
- Internet reachability + latency (ping 8.8.8.8)
- Configurable refresh interval, IP blur, hide/reorder/rename interfaces
- Desktop notifications on interface up/down changes
- Bar toggle icon (optional)
- Settings form (gear) writes `~/.config/omarchy/opensense-widget/config.json`

## Requirements

- Omarchy (Arch + Hyprland + Quickshell shell)
- `python3`, `curl`, `jq`, `ping` (iputils), `notify-send` (libnotify)
- OPNsense firewall with API access enabled

## Install

```bash
git clone https://github.com/iainlennox/opensense-widget-omarchy.git
cd opensense-widget-omarchy
./install.sh            # installs the floating panel widget
./install.sh --bar      # also add a bar icon to the right section
```

The shell watches `~/.config/omarchy/plugins/` and `shell.json`, so the widget
appears shortly after install — no restart required. Remove it with:

```bash
./install.sh --uninstall
```

## Configure

1. In OPNsense, go to **System > Access > Users**, edit your user and add an
   **API key**.
2. Click the **⚙** gear on the widget and enter:
   - Base URL (e.g. `https://192.168.1.1`)
   - API Key
   - API Secret
   - Refresh interval (default 5 s)
3. Add servers (hostname / custom name / OS) and services (Plex or DNS) as
   desired, then **Save**.

Config is stored at `~/.config/omarchy/opensense-widget/config.json`.

## Usage

- The widget floats bottom-right and is visible by default.
- Click the **—** button to minimise it; add the bar icon to reopen it.
- Click an interface card to expand/collapse its detail row + sparkline.
- The bar icon (if installed) toggles the widget via the shell.
- The footer shows worst health, combined bandwidth and internet latency.

## Files

| File | Purpose |
|------|---------|
| `manifest.json` | Omarchy plugin manifest (`panel` + `bar-widget`, `keepLoaded`) |
| `Panel.qml` | Floating widget UI + polling (panel entry point) |
| `BarWidget.qml` | Optional bar toggle icon (bar-widget entry point) |
| `Model.js` | Pure logic: bandwidth/uptime/health formatting, sparkline points |
| `config.js` | Pure config model (parse/serialize/normalise) |
| `opensense-status.py` | Gatherer: OPNsense API, ICMP ping, Plex/DNS checks → JSON |
| `install.sh` / `uninstall.sh` | Install/remove the plugin and register it in `shell.json` |

## Author

**Iain Lennox** — [iain@lennoxfamily.net](mailto:iain@lennoxfamily.net)

Lennox Technology

---

*Made with ❤️ in Scotland*
