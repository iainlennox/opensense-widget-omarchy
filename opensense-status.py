#!/usr/bin/env python3
"""opensense-status.py — data gatherer for the OPNsense Widget.

Reads the widget's config file and emits a single line of JSON per subcommand,
so the Quickshell panel can poll it with a Process + SplitParser on whatever
cadence it wants. Each subcommand never blocks the others: interfaces/bandwidth
poll fast, servers poll slower, services slower still.

Subcommands
-----------
  interfaces   OPNsense interface overview + traffic byte counters
  servers      ICMP ping each configured server
  services     Plex (/identity, /status/sessions) and DNS (UDP 53) checks
  internet     ICMP ping 8.8.8.8

Every subcommand prints exactly one JSON object to stdout (never throws).
"""

import base64
import json
import os
import re
import socket
import ssl
import struct
import subprocess
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET

DEFAULT_CONFIG = {
    "baseUrl": "https://192.168.1.1",
    "apiKey": "",
    "apiSecret": "",
    "refreshIntervalSeconds": 5,
    "blurIpAddress": False,
    "interfaces": [],
    "servers": [],
    "services": [],
}

DNS_DOMAIN = "google.com"


def eprint(msg):
    sys.stderr.write(msg + "\n")


def load_config(path):
    if not path or not os.path.isfile(path):
        return dict(DEFAULT_CONFIG)
    try:
        with open(path, "r") as fh:
            raw = json.load(fh)
        cfg = dict(DEFAULT_CONFIG)
        for k in ("baseUrl", "apiKey", "apiSecret"):
            if isinstance(raw.get(k), str):
                cfg[k] = raw[k]
        if isinstance(raw.get("refreshIntervalSeconds"), (int, float)) and raw["refreshIntervalSeconds"] > 0:
            cfg["refreshIntervalSeconds"] = int(raw["refreshIntervalSeconds"])
        if isinstance(raw.get("blurIpAddress"), bool):
            cfg["blurIpAddress"] = raw["blurIpAddress"]
        for key, normalizer in (("interfaces", _norm_iface), ("servers", _norm_server), ("services", _norm_service)):
            if isinstance(raw.get(key), list):
                cfg[key] = [normalizer(x) for x in raw[key]]
        return cfg
    except Exception as e:
        eprint("config load failed: %s" % e)
        return dict(DEFAULT_CONFIG)


def _norm_iface(x):
    if not isinstance(x, dict):
        return {}
    return {
        "deviceName": x.get("deviceName") or "",
        "customName": x.get("customName") or None,
        "isHidden": bool(x.get("isHidden")),
        "order": int(x.get("order") or 0),
    }


def _norm_server(x):
    if not isinstance(x, dict):
        return {}
    return {
        "hostname": x.get("hostname") or "",
        "customName": x.get("customName") or None,
        "description": x.get("description") or None,
        "operatingSystem": x.get("operatingSystem") or "Windows Server",
        "order": int(x.get("order") or 0),
    }


def _norm_service(x):
    if not isinstance(x, dict):
        return {}
    return {
        "serviceType": x.get("serviceType") or "Plex",
        "hostname": x.get("hostname") or "",
        "customName": x.get("customName") or None,
        "token": x.get("token") or None,
        "order": int(x.get("order") or 0),
    }


# ---------------------------------------------------------------- HTTP helpers

def http_get(url, auth=None, timeout=10, headers=None, verify_ssl=False):
    """GET a URL with optional HTTP Basic auth. Returns (status, body)."""
    ctx = ssl.create_default_context()
    if not verify_ssl:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    req = urllib.request.Request(url)
    req.add_header("Accept", "application/json")
    if headers:
        for k, v in headers.items():
            req.add_header(k, v)
    if auth:
        creds = base64.b64encode(("%s:%s" % auth).encode("ascii")).decode("ascii")
        req.add_header("Authorization", "Basic " + creds)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            body = resp.read().decode("utf-8", "replace")
            return resp.status, body
    except urllib.error.HTTPError as e:
        try:
            body = e.read().decode("utf-8", "replace")
        except Exception:
            body = ""
        return e.code, body
    except Exception as e:
        eprint("http_get failed for %s: %s" % (url, e))
        return None, ""


def _opnsense_get(cfg, path):
    base = (cfg.get("baseUrl") or "").rstrip("/")
    if not base:
        return None
    auth = (cfg.get("apiKey") or "", cfg.get("apiSecret") or "")
    return http_get(base + path, auth=auth)


def get_interfaces(cfg):
    """OPNsense interface overview + traffic counters in one pass."""
    result = {"ok": False, "error": "", "interfaces": []}
    status, body = _opnsense_get(cfg, "/api/interfaces/overview/interfacesInfo")
    if status is None or status >= 400:
        result["error"] = "HTTP %s" % (status if status else "unreachable")
        return result

    try:
        data = json.loads(body)
    except Exception as e:
        result["error"] = "bad JSON: %s" % e
        return result

    rows = data.get("rows") or []
    traffic = {}
    t_status, t_body = _opnsense_get(cfg, "/api/diagnostics/traffic/interface")
    if t_status is not None and t_status < 400:
        try:
            tdata = json.loads(t_body)
            traffic = tdata.get("interfaces") or {}
        except Exception:
            traffic = {}

    ifaces = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        name = row.get("device") or ""
        ip = row.get("addr4") or ""
        ipv4 = row.get("ipv4")
        if isinstance(ipv4, list) and ipv4 and isinstance(ipv4[0], dict):
            ip = ipv4[0].get("ipaddr") or ip
        tr = traffic.get(name) or {}
        rx = _as_int(tr.get("bytes received") if isinstance(tr, dict) else None)
        tx = _as_int(tr.get("bytes transmitted") if isinstance(tr, dict) else None)
        ifaces.append({
            "name": name,
            "description": row.get("description") or "",
            "status": (row.get("status") or "").lower(),
            "ip": ip,
            "mac": row.get("macaddr") or "",
            "linkSpeed": row.get("media") or "",
            "uptime": row.get("uptime") or "",
            "rxBytes": rx,
            "txBytes": tx,
        })
    result["ok"] = True
    result["interfaces"] = ifaces
    return result


def _as_int(value):
    try:
        return int(float(value))
    except Exception:
        return 0


# ---------------------------------------------------------------- ping

def ping(host, timeout=3):
    """ICMP ping. Returns (online, latency_ms, ip)."""
    try:
        proc = subprocess.run(
            ["ping", "-c", "1", "-W", str(timeout), "-n", host],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout + 1,
        )
    except Exception as e:
        eprint("ping failed for %s: %s" % (host, e))
        return False, 0, ""
    out = proc.stdout or ""
    if proc.returncode != 0:
        return False, 0, ""
    m = re.search(r"time[=<]([\d.]+)\s*ms", out)
    latency = float(m.group(1)) if m else 0.0
    ip = ""
    ipm = re.search(r"\(([\d.]+)\)|bytes from\s+([\d.]+)", out)
    if ipm:
        ip = ipm.group(1) or ipm.group(2) or ""
    return True, int(round(latency)), ip


def get_servers(cfg):
    servers = []
    for s in cfg.get("servers") or []:
        host = s.get("hostname") or ""
        if not host:
            continue
        online, latency, ip = ping(host)
        servers.append({
            "hostname": host,
            "online": online,
            "latencyMs": latency,
            "ip": ip,
        })
    return {"servers": servers}


def get_internet(cfg):
    online, latency, ip = ping("8.8.8.8", timeout=5)
    return {"reachable": online, "latencyMs": latency}


# ---------------------------------------------------------------- services

def get_services(cfg):
    services = []
    for s in cfg.get("services") or []:
        stype = s.get("serviceType") or "Plex"
        host = s.get("hostname") or ""
        token = s.get("token") or None
        if not host:
            continue
        if stype == "Plex":
            services.append(check_plex(host, token))
        elif stype == "DNS":
            services.append(check_dns(host))
        else:
            services.append({
                "type": stype, "hostname": host, "online": False,
                "detail": "Unknown service type", "latencyMs": 0, "serverVersion": "",
            })
    return {"services": services}


def _plex_base(host):
    base = (host or "").rstrip("/")
    if not re.match(r"^https?://", base, re.IGNORECASE):
        base = "http://" + base + ":32400"
    return base


def check_plex(host, token):
    base = _plex_base(host)
    result = {"type": "Plex", "hostname": host, "online": False, "detail": "",
              "latencyMs": 0, "serverVersion": ""}
    suffix = ("?X-Plex-Token=" + token) if token else ""
    start = time.time()
    status, body = http_get(base + "/identity" + suffix, timeout=6,
                            headers={"Accept": "application/xml"})
    latency = int(round((time.time() - start) * 1000))
    if status is None or status >= 400:
        result["detail"] = "No response"
        return result
    version = ""
    try:
        root = ET.fromstring(body)
        version = root.get("version") or ""
    except Exception:
        pass
    result["online"] = True
    result["latencyMs"] = latency
    result["serverVersion"] = version

    # Active sessions
    sessions = "0"
    detail = ""
    sstatus, sbody = http_get(base + "/status/sessions" + suffix, timeout=6,
                              headers={"Accept": "application/xml"})
    if sstatus is not None and sstatus < 400:
        try:
            root = ET.fromstring(sbody)
            size = root.get("size")
            if size:
                sessions = size
            titles = []
            for el in root.iter():
                if el.get("title") and el.get("ratingKey"):
                    user = ""
                    for u in el.iter():
                        if u.tag.split("}")[-1] == "User" and u.get("title"):
                            user = u.get("title")
                            break
                    titles.append("%s (%s)" % (el.get("title"), user) if user else el.get("title"))
            if titles:
                detail = ", ".join(titles[:8])
        except Exception:
            pass
    result["detail"] = detail if detail else ("%s streams" % sessions if sessions not in ("0", "") else "No streams")
    return result


def check_dns(host):
    result = {"type": "DNS", "hostname": host, "online": False, "detail": "",
              "latencyMs": 0, "serverVersion": ""}
    query = build_dns_query(DNS_DOMAIN)
    start = time.time()
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(5)
        sock.connect((host, 53))
        sock.send(query)
        data = sock.recv(512)
        sock.close()
        latency = int(round((time.time() - start) * 1000))
        rcode, ip, ttl = parse_dns_response(data)
        result["online"] = True
        result["latencyMs"] = latency
        if rcode == 0:
            result["detail"] = "%s \u2192 %s \u00b7 NOERROR \u00b7 TTL %s" % (DNS_DOMAIN, ip or "?", ttl)
        elif rcode == 3:
            result["detail"] = "%s \u00b7 NXDOMAIN" % DNS_DOMAIN
        elif rcode == 2:
            result["detail"] = "%s \u00b7 SERVFAIL" % DNS_DOMAIN
        else:
            result["detail"] = "%s \u00b7 RCODE %s" % (DNS_DOMAIN, rcode)
    except Exception as e:
        result["detail"] = "No response"
    return result


def build_dns_query(domain):
    header = struct.pack(">HHHHHH", 0xABCD, 0x0100, 1, 0, 0, 0)
    qname = b""
    for label in domain.split("."):
        qname += bytes([len(label)]) + label.encode("ascii")
    qname += b"\x00"
    question = qname + struct.pack(">HH", 1, 1)
    return header + question


def parse_dns_response(data):
    if len(data) < 12:
        return -1, "", 0
    rcode = data[3] & 0x0F
    answer_count = (data[6] << 8) | data[7]
    if rcode != 0 or answer_count == 0:
        return rcode, "", 0
    pos = 12
    while pos < len(data) and data[pos] != 0:
        if (data[pos] & 0xC0) == 0xC0:
            pos += 2
            break
        pos += data[pos] + 1
    if pos < len(data) and data[pos] == 0:
        pos += 1
    pos += 4
    ip = ""
    ttl = 0
    for _ in range(answer_count):
        if pos + 1 >= len(data):
            break
        if (data[pos] & 0xC0) == 0xC0:
            pos += 2
        else:
            while pos < len(data) and data[pos] != 0:
                if (data[pos] & 0xC0) == 0xC0:
                    pos += 2
                    break
                pos += data[pos] + 1
            pos += 1
        if pos + 10 > len(data):
            break
        qtype = (data[pos] << 8) | data[pos + 1]
        pos += 2
        pos += 2
        ttl = (data[pos] << 24) | (data[pos + 1] << 16) | (data[pos + 2] << 8) | data[pos + 3]
        pos += 4
        rdlength = (data[pos] << 8) | data[pos + 1]
        pos += 2
        if qtype == 1 and rdlength == 4 and pos + 4 <= len(data):
            ip = "%d.%d.%d.%d" % (data[pos], data[pos + 1], data[pos + 2], data[pos + 3])
            return rcode, ip, ttl
        pos += rdlength
    return rcode, ip, ttl


# ---------------------------------------------------------------- main

def main(argv):
    if len(argv) < 2:
        eprint("usage: opensense-status.py <subcommand> [--config PATH]")
        print(json.dumps({"error": "no subcommand"}))
        return 1
    sub = argv[1]
    cfg_path = None
    if "--config" in argv:
        try:
            cfg_path = argv[argv.index("--config") + 1]
        except IndexError:
            cfg_path = None
    cfg = load_config(cfg_path)

    if sub == "interfaces":
        print(json.dumps(get_interfaces(cfg)))
    elif sub == "servers":
        print(json.dumps(get_servers(cfg)))
    elif sub == "services":
        print(json.dumps(get_services(cfg)))
    elif sub == "internet":
        print(json.dumps(get_internet(cfg)))
    else:
        eprint("unknown subcommand: %s" % sub)
        print(json.dumps({"error": "unknown subcommand"}))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
