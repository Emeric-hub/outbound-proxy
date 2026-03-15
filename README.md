# Proxy Stack

A self-contained, configurable HTTP/HTTPS filtering proxy with optional log shipping to Kibana.

**Core stack:** E2Guardian (content filter) → Squid (caching upstream) → Internet

**Optional ELK stack** (`docker-compose.override.yml`): Filebeat → Elasticsearch → Kibana

---

## Architecture

```
Client → E2Guardian :8080 → Squid :3128 → Internet
              │
         Block page (template.html)
         when URL/content is banned

              │ access.log (FIFO+tee)
              ▼
         Filebeat → Elasticsearch → Kibana :5601
```

### Containers

| Container | Role |
|---|---|
| `cert-init` | Generates CA cert + keys on first run (one-shot) |
| `e2guardian` | Content filtering, site blocking, SSL MITM |
| `squid` | Caching upstream proxy |
| `e2guardian-watcher` | Sends SIGHUP to e2guardian when list files change |
| `filebeat` ¹ | Ships access logs to Elasticsearch |
| `elasticsearch` ¹ | Log storage and search |
| `kibana` ¹ | Log visualisation on port 5601 |
| `kibana-init` ¹ | Provisions ingest pipelines and data views (one-shot) |

¹ Optional — defined in `docker-compose.override.yml`, loaded automatically by `docker compose`.

---

## Quick Start

### Prerequisites

- Docker + Docker Compose
- CA certificate trusted in your OS/browser (see below)

### 1. Start the stack

```bash
# Proxy only
docker compose -f docker-compose.yml up -d

# Proxy + ELK logging
docker compose up -d
```

On first run `cert-init` generates `./e2guardian/certs/ca.crt`, `ca.key`, and `cert.key`.

### 2. Trust the CA certificate

Import `./e2guardian/certs/ca.crt` into your trust store so browsers accept the intercepted HTTPS certs.

**Windows**
```powershell
certutil -addstore Root .\e2guardian\certs\ca.crt
```

**macOS**
```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain e2guardian/certs/ca.crt
```

**Linux (Debian/Ubuntu)**
```bash
sudo cp e2guardian/certs/ca.crt /usr/local/share/ca-certificates/proxy-ca.crt
sudo update-ca-certificates
```

**Firefox** — Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import

**Chrome/Edge** — Settings → Privacy and security → Security → Manage certificates → Authorities → Import

### 3. Configure your browser/system proxy

Point your HTTP and HTTPS proxy to `localhost:8080`.

---

## WPAD / PAC File

The stack ships a **WPAD** (Web Proxy Auto-Discovery) server that lets browsers and operating systems discover proxy settings automatically.

### How it works

The `wpad` container serves `wpad/wpad.dat` (a JavaScript PAC file) on **port 80**:

```
http://<proxy-host>/wpad.dat
```

Clients fetch this file, run the `FindProxyForURL()` function, and route matching traffic through `E2Guardian:8080`.

### Configure the proxy address

Edit `wpad/wpad.dat` and set `PROXY_HOST` to the hostname or IP address of the machine running the stack:

```javascript
var PROXY_HOST = "192.168.1.100";  // ← change this
var PROXY_PORT = "8080";
```

### Distribute via DHCP (option 252)

Configure your DHCP server to push the PAC URL to clients automatically.

**ISC DHCP (`dhcpd.conf`)**
```
option local-proxy-config code 252 = text;

subnet 192.168.1.0 netmask 255.255.255.0 {
    option local-proxy-config "http://192.168.1.100/wpad.dat";
    # ... other options
}
```

**dnsmasq**
```
dhcp-option=252,"http://192.168.1.100/wpad.dat"
```

**Windows Server DHCP** — Scope Options → Add option 252 (type: String) with value `http://192.168.1.100/wpad.dat`.

### DNS-based WPAD auto-discovery

Browsers that support WPAD auto-discovery request `http://wpad.<domain>/wpad.dat` automatically (no manual config needed). Add a DNS entry pointing `wpad` to the proxy host:

```
# In your DNS zone or /etc/hosts:
192.168.1.100   wpad   wpad.example.com
```

> **Security note:** WPAD auto-discovery is disabled by default in modern Windows (KB3165191). It is also a known attack vector — only enable it on trusted internal networks.

### Distribute via OpenVPN

Push proxy settings to VPN clients so they use the proxy automatically when connected.

**OpenVPN server config (`server.conf`)**
```
# HTTP and HTTPS proxy
push "dhcp-option PROXY_HTTP 192.168.1.100 8080"
push "dhcp-option PROXY_HTTPS 192.168.1.100 8080"

# PAC URL (supported by Windows and some Linux clients)
push "dhcp-option PROXY_AUTO_CONFIG_URL http://192.168.1.100/wpad.dat"
```

> **Note:** `PROXY_HTTP` / `PROXY_HTTPS` push directives are honoured by the OpenVPN Windows client and Network Manager on Linux. macOS clients may require manual PAC URL configuration.

---

## Feature Toggles

Edit `.env`, then restart the `e2guardian` container (`docker compose restart e2guardian`):

| Variable | Default | Description |
|---|---|---|
| `E2G_CONTENT_FILTER` | `on` | Phrase-based scoring (profanity, violence, adult content…). Set `off` to disable. |
| `E2G_SITE_BLOCK` | `on` | Enforce `e2guardian/lists/bannedsitelist`. Set `off` to allow all sites. |
| `E2G_SSL_MITM` | `on` | HTTPS interception. Set `off` to pass HTTPS tunnels through uninspected. |
| `E2G_BYPASS` | `off` | When `on`, users can click through a block page to proceed anyway. |

```ini
# .env example
E2G_CONTENT_FILTER=on
E2G_SITE_BLOCK=on
E2G_SSL_MITM=on
E2G_BYPASS=off
```

---

## Custom Lists

All list files live in `./e2guardian/lists/` and are mounted into the container at runtime. The **watcher service** automatically sends a graceful reload (SIGHUP) to e2guardian whenever any file in that directory changes — no container restart needed.

### Blocking sites

Add entries to `e2guardian/lists/bannedsitelist`:

```
# Leading dot matches the domain and all subdomains
.example.com

# Bare entry matches the exact hostname only
ads.tracker.net
```

### Allowing sites (exceptions)

Add entries to `e2guardian/lists/exceptionsitelist` using the same format. Exception list entries override the ban list.

### Other lists

The `lists/` directory contains the full set of e2guardian list files. Edit any of them and the watcher will hot-reload e2guardian within ~1 second.

---

## Block Page

The block page template is at `e2guardian/templates/template.html`. Edit it freely — the file is volume-mounted so changes take effect after an e2guardian restart.

Available template variables substituted by e2guardian at block time:

| Variable | Value |
|---|---|
| `-URL-` | The blocked URL |
| `-REASONGIVEN-` | Why it was blocked |
| `-IP-` | Client IP address |
| `-USER-` | Authenticated username (or `-`) |
| `-FILTERGROUP-` | Filter group name |

---

## Logging (ELK)

When the full stack is running, access logs flow automatically:

```
e2guardian stderr → FIFO+tee → /var/log/e2guardian/access.log → Filebeat → Elasticsearch
```

> **Note:** e2guardian v5's file-based `set_accesslog` destination is silently ignored in the current build. `start.sh` works around this by piping stderr through `tee` to write the log file while keeping output visible in `docker compose logs`.

### Kibana

Open `http://localhost:5601` and log in with the `KIBANA_USER` / `KIBANA_PASSWORD` credentials from `.env`. Two data views are pre-provisioned:

| Data view | Index | Content |
|---|---|---|
| E2Guardian Access Logs | `e2guardian-access-*` | All proxy requests with parsed fields |
| Squid Access Logs | `squid-access-*` | Upstream cache hit/miss stats |

Parsed fields for e2guardian entries:

| Field | Description |
|---|---|
| `@timestamp` | Request time (from Unix epoch in log) |
| `e2g.client_ip` | Client IP address |
| `e2g.url` | Requested URL |
| `e2g.method` | HTTP method |
| `e2g.http_code` | Response status code |
| `e2g.bytes` | Response body size |
| `e2g.content_type` | MIME type |
| `e2g.response_ms` | Filtering + response time (ms) |
| `e2g.reason` | Block/allow reason (e.g. `*DENIED* Blocked site: …`) |
| `e2g.message_no` | Filter result code (0 = pass, 500 = blocked, 602 = exception) |
| `e2g.naughtiness` | Phrase-scoring naughtiness score |
| `e2g.filter_group` | Filter group name |

---

## Troubleshooting

### `*DENIED* Failed to negotiate ssl connection to client`

E2Guardian attempted SSL MITM on an HTTPS connection but the TLS handshake with the client failed. Two common causes:

**1. CA certificate not trusted**

The client (browser or OS) doesn't trust the proxy CA. Import `./e2guardian/certs/ca.crt` into your trust store — see [Trust the CA certificate](#2-trust-the-ca-certificate) above.

**2. Certificate pinning**

Some applications hard-code expected certificate fingerprints and reject any certificate not in their pinset (even a trusted CA). These connections cannot be intercepted and must be passed through as opaque CONNECT tunnels.

**Identify the failing domain:**

```bash
docker compose logs e2guardian 2>&1 | grep -i "failed to negotiate" | tail -20
```

The URL field in the surrounding log lines shows the domain. Alternatively, look for `CONNECT` entries just before the error.

**Fix: add the domain to the SSL grey list**

Edit `e2guardian/lists/greysslsitelist` and add the domain with a leading dot to match all subdomains:

```
# My app uses cert pinning
.example-app.com
```

The watcher service will send SIGHUP to e2guardian within ~1 second — no restart needed.

The file ships with bypass entries for common certificate-pinning services (Apple, Google, Microsoft, Mozilla, OCSP/CRL endpoints). If a service you use isn't listed, add it here.

> **Note:** Domains in `greysslsitelist` are still subject to URL and content filtering — only SSL MITM is skipped. To bypass *all* filtering (including content scoring), use `exceptionsitelist` instead.

---

## Testing

```bash
bash test.sh
```

The script runs a series of HTTP/HTTPS requests through the proxy and checks that allowed sites pass and banned sites are blocked. Set `CACERT` if the CA cert is in a non-default location:

```bash
CACERT=/path/to/ca.crt bash test.sh
```

---

## Directory Structure

```
proxy/
├── docker-compose.yml              # Core stack (proxy only)
├── docker-compose.override.yml     # ELK logging stack (auto-loaded)
├── .env                            # Feature toggles + image versions
├── test.sh                         # Connectivity + block tests
├── e2guardian/
│   ├── start.sh                    # Startup script: patches config, generates site.story
│   ├── certs/                      # CA cert + keys (generated on first run)
│   │   ├── ca.crt                  # Import this into your OS/browser trust store
│   │   ├── ca.key
│   │   └── cert.key
│   ├── lists/                      # All e2guardian list files (hot-reloaded on change)
│   │   ├── bannedsitelist          # Sites to block
│   │   ├── exceptionsitelist       # Sites to always allow
│   │   └── ...                     # Default e2guardian lists
│   └── templates/
│       └── template.html           # Block page template
├── squid/
│   └── squid.conf                  # Squid config overrides
├── filebeat/
│   └── filebeat.yml                # Log shipping config
└── kibana-init/
    └── init.sh                     # Provisions ingest pipelines + data views
```
