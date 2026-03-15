# TODO / Improvement Ideas

Items are grouped by theme. Security items are marked **[SEC]**.

---

## Security

- **[SEC] CA private key is world-readable** — `cert-init` runs `chmod 644 /certs/ca.key`. A
  leaked `ca.key` lets anyone decrypt all HTTPS traffic that was intercepted. Fix: `chmod 640`
  (root:e2guardian) or `chmod 600`. The comment in `docker-compose.yml` ("these files never leave
  the Docker volume") understates the risk — any process with access to the named volume can read
  it.

- **[SEC] Docker socket mounted in watcher container** — `e2guardian-watcher` mounts
  `/var/run/docker.sock`, which is equivalent to giving that container full root access to the host.
  If the container is ever compromised (e.g. via a crafted list file), the attacker gets the host.
  Alternatives: use a socket proxy like `docker-socket-proxy` (expose only the minimal API needed),
  or replace the watcher with a sidecar that shares a volume and sends SIGHUP via a shared PID
  namespace (`pid: service:e2guardian`).

- **[SEC] No proxy authentication** — Any client that can reach port 8080 can use the proxy. For a
  multi-user or semi-trusted network, add basic auth or LDAP auth in e2guardian
  (`authplugin = 'proxy-basic'` / `authplugin = 'proxy-ntlm'`).

- **[SEC] Squid ACL is too broad** — `acl docker_net src all` + `http_access allow docker_net`
  effectively allows anyone. Tighten to the specific Docker network CIDR (e.g.
  `acl docker_net src 172.16.0.0/12`) so squid only accepts connections from e2guardian, not from
  any container that happens to be added to `proxy-net`.

- **[SEC] No log integrity / tamper evidence** — Access logs are stored in a plain named volume.
  Logs can be silently modified or rotated away. Consider shipping to an append-only destination or
  adding a checksum side-channel.

---

## Reliability & Correctness

- **Missing e2guardian healthcheck** — `e2guardian-watcher` uses `condition: service_healthy` but
  `e2guardian` has no `healthcheck:` block. Docker will never mark it healthy, so the watcher
  silently never starts. Add a healthcheck such as:
  ```yaml
  healthcheck:
    test: ["CMD-SHELL", "curl -sf http://localhost:8080 -o /dev/null || exit 1"]
    interval: 10s
    timeout: 5s
    retries: 5
    start_period: 15s
  ```

- **FIFO + tee buffering** — The `start.sh` FIFO approach can silently drop log lines if the `tee`
  background process falls behind (e.g. disk full, slow volume). Consider adding `sync`/`fsync`
  guarantees or monitoring the log file size.

- **access.log grows unbounded** — There is no log rotation. On a busy network the named volume
  will fill up. Add a `logrotate` config or configure Filebeat's `clean_inactive` /
  `close_inactive` settings, and add a cron/logrotate sidecar.

- **Non-log lines in access.log** — The FIFO captures all of e2guardian's stderr, including startup
  messages (`master: Started successfully.`) and reload notices. These are indexed in Elasticsearch
  as raw `message` documents. They are harmless but noisy. Filter them out in Filebeat with a
  `drop_event` processor (drop lines that don't match `^[0-9]+ [0-9]+\.`).

- **`set_accesslog = 'file:...'` silently ignored** — e2guardian v5.6 does not honour
  file-destination `set_accesslog` entries. The FIFO workaround works but is fragile. Report
  upstream or watch for a fix; when resolved the FIFO section in `start.sh` can be replaced with
  the native setting.

---

## Observability

- **No Kibana dashboards** — `kibana-init` creates data views but no dashboards or visualisations.
  Add pre-built dashboards for: top blocked domains, top clients, blocked vs allowed ratio, HTTPS vs
  HTTP split, and naughtiness score distribution.

- **No alerting** — Elasticsearch Watcher (or Kibana Alerting) could fire on spikes in blocked
  requests, repeated bypass attempts, or novel blocked categories.

- **Squid cache metrics not captured** — `dstats.log` from e2guardian is ignored; Squid's
  `cache.log` is also not shipped. Adding these would show cache hit rates and upstream latency.

---

## Maintainability

- **Unpinned image tags** — `alpine:latest`, `ubuntu/squid:latest`, and `alpine/curl:latest` will
  silently drift. Pin to digest-locked tags (e.g. `alpine:3.21`) so builds are reproducible.

- **`.env` inline comments** — Entries like `E2G_BYPASS=on   # comment` work with Docker Compose
  but will break if the file is sourced by a strict POSIX shell (`sh`). Move comments to their own
  lines.

- **`test.sh` references a dead domain** — `linkadd.de` is a parked/expired domain that no longer
  resolves; the block test for it always fails. Replace with a stable test domain or a local
  override.

- **`e2guardian/e2guardian.conf` and `e2guardianf1.conf` are committed** — These are copies of the
  image defaults, checked in as a reference. They're not mounted into the container and can drift
  from the actual image defaults over time. Either remove them (relying on `start.sh` patches only)
  or make the intent clear in a comment.

- **No CI** — Add a GitHub Actions workflow that runs `docker compose config` (validates compose
  files) and `bash test.sh` (smoke-tests the proxy) on every push.

---

## Features

- **Per-user / per-group filtering** — e2guardian supports multiple filter groups. Combine with
  proxy auth to give different groups (e.g. staff vs. guests) different block lists and phrase
  limits.

- **Time-based rules** — Block social media only during work hours using e2guardian's time-limit
  story functions.

- **Custom deny page per category** — The current template uses `-REASONGIVEN-` for all blocks.
  Serve a different template for, e.g., malware blocks vs. policy blocks.

- **BYOCA (Bring Your Own CA)** — Document and test the workflow for replacing the
  auto-generated CA with a corporate / existing CA (mount your own `ca.crt` / `ca.key` into
  `./e2guardian/certs/` before first run).

- **IPv6 support** — The proxy currently binds on IPv4 only (`8080`). Add a `filterip` entry for
  `::` in `e2guardian.conf` for dual-stack environments.
