#!/bin/sh
# Wait for Elasticsearch and Kibana, then provision ingest pipelines, data views,
# the Kibana admin user, and import saved objects.
set -e

ES="http://elasticsearch:9200"
KIBANA="http://kibana:5601"

# ── Wait for Elasticsearch ────────────────────────────────────────────────────
echo "Waiting for Elasticsearch..."
until curl -sf "${ES}/_cluster/health" | grep -qE '"status":"(green|yellow)"'; do
  sleep 5
done
echo "Elasticsearch is ready."

# ── Create ingest pipelines ───────────────────────────────────────────────────
create_pipeline() {
  curl -sf -X PUT "${ES}/_ingest/pipeline/${1}" \
    -H "Content-Type: application/json" \
    -d "${2}" > /dev/null \
    && echo "[OK] Pipeline '${1}' created" \
    || echo "[WARN] Could not create pipeline '${1}'"
}

# Squid native log format:
# 1234567890.123    123 192.168.1.1 TCP_MISS/200 1234 GET http://example.com/ - DIRECT/93.184.216.34 text/html
create_pipeline "squid-access-parse" '{
  "description": "Parse Squid native access log",
  "processors": [
    {
      "grok": {
        "field": "message",
        "patterns": [
          "%{NUMBER:squid.access_time}\\s+%{NUMBER:squid.elapsed_ms}\\s+%{IPORHOST:squid.client_ip}\\s+%{WORD:squid.cache_result}/%{NUMBER:squid.http_code}\\s+%{NUMBER:squid.bytes}\\s+%{WORD:squid.method}\\s+%{NOTSPACE:squid.url}\\s+%{NOTSPACE:squid.user}\\s+%{WORD:squid.peer_action}/%{NOTSPACE:squid.server_ip}\\s+%{NOTSPACE:squid.content_type}"
        ],
        "ignore_failure": true
      }
    },
    {
      "date": {
        "field": "squid.access_time",
        "formats": ["UNIX"],
        "target_field": "@timestamp",
        "ignore_failure": true
      }
    }
  ]
}'

# E2Guardian log format (logformat8, tab-separated, 22 fields):
# Fields: EndUtime Server.Blank User ClientIP ClientHostOrIP Url ReqType ResCode
#         BodySize MimeType UserAgent.Blank Blank DurationMs Blank MessageNo
#         WhatCombi Naughtiness Category GroupName GroupNo SearchTerms ExtFlags
#
# Stderr output prepends an integer epoch before the tab-separated record;
# the file log starts directly with the float epoch.
# Two patterns handle both forms.
create_pipeline "e2guardian-access-parse" '{
  "description": "Parse E2Guardian v5 access log (logformat8, tab-separated)",
  "processors": [
    {
      "grok": {
        "field": "message",
        "pattern_definitions": {
          "NOTHTAB": "[^\\t]*"
        },
        "patterns": [
          "%{NUMBER}\\s%{NUMBER:e2g.timestamp}\\t(?:[^\\t]*)\\t%{NOTHTAB:e2g.user}\\t%{NOTHTAB:e2g.client_ip}\\t(?:[^\\t]*)\\t%{NOTSPACE:e2g.url}\\t%{WORD:e2g.method}\\t%{NUMBER:e2g.http_code}\\t%{NUMBER:e2g.bytes}\\t%{NOTHTAB:e2g.content_type}\\t(?:[^\\t]*)\\t(?:[^\\t]*)\\t%{NUMBER:e2g.response_ms}\\t(?:[^\\t]*)\\t%{NUMBER:e2g.message_no}\\t%{NOTHTAB:e2g.reason}\\t%{NUMBER:e2g.naughtiness}\\t%{NOTHTAB:e2g.category}\\t%{NOTHTAB:e2g.filter_group}",
          "%{NUMBER:e2g.timestamp}\\t(?:[^\\t]*)\\t%{NOTHTAB:e2g.user}\\t%{NOTHTAB:e2g.client_ip}\\t(?:[^\\t]*)\\t%{NOTSPACE:e2g.url}\\t%{WORD:e2g.method}\\t%{NUMBER:e2g.http_code}\\t%{NUMBER:e2g.bytes}\\t%{NOTHTAB:e2g.content_type}\\t(?:[^\\t]*)\\t(?:[^\\t]*)\\t%{NUMBER:e2g.response_ms}\\t(?:[^\\t]*)\\t%{NUMBER:e2g.message_no}\\t%{NOTHTAB:e2g.reason}\\t%{NUMBER:e2g.naughtiness}\\t%{NOTHTAB:e2g.category}\\t%{NOTHTAB:e2g.filter_group}"
        ],
        "ignore_failure": true
      }
    },
    {
      "date": {
        "field": "e2g.timestamp",
        "formats": ["UNIX"],
        "target_field": "@timestamp",
        "ignore_failure": true
      }
    },
    {"convert": {"field": "e2g.http_code",    "type": "integer", "ignore_failure": true}},
    {"convert": {"field": "e2g.bytes",        "type": "long",    "ignore_failure": true}},
    {"convert": {"field": "e2g.response_ms",  "type": "integer", "ignore_failure": true}},
    {"convert": {"field": "e2g.message_no",   "type": "integer", "ignore_failure": true}},
    {"convert": {"field": "e2g.naughtiness",  "type": "integer", "ignore_failure": true}}
  ]
}'

# ── Wait for Kibana ───────────────────────────────────────────────────────────
echo "Waiting for Kibana..."
until curl -sf "${KIBANA}/api/status" | grep -q '"level":"available"'; do
  sleep 5
done
echo "Kibana is ready."

# ── Create data views ─────────────────────────────────────────────────────────
create_data_view() {
  curl -sf \
    -X POST "${KIBANA}/api/data_views/data_view" \
    -H "Content-Type: application/json" \
    -H "kbn-xsrf: true" \
    -d "{
      \"override\": true,
      \"data_view\": {
        \"title\": \"${1}\",
        \"name\": \"${2}\",
        \"timeFieldName\": \"@timestamp\"
      }
    }" | grep -q '"id"' && echo "[OK] Data view '${2}' created" \
                        || echo "[WARN] Could not create data view '${2}'"
}

create_data_view "squid-access-*"      "Squid Access Logs"
create_data_view "e2guardian-access-*" "E2Guardian Access Logs"

# ── Import saved objects (dashboards, visualisations, searches…) ──────────────
# Drop Kibana/export.ndjson at the repo root to have it auto-imported on startup.
# overwrite=true keeps the import idempotent: re-running kibana-init won't fail
# if the objects already exist.
EXPORT="/export.ndjson"
if [ -f "${EXPORT}" ]; then
  curl -sf \
    -X POST "${KIBANA}/api/saved_objects/_import?overwrite=true" \
    -H "kbn-xsrf: true" \
    -F "file=@${EXPORT}" > /dev/null \
    && echo "[OK] Saved objects imported from ${EXPORT}" \
    || echo "[WARN] Could not import saved objects from ${EXPORT}"
else
  echo "[INFO] No export.ndjson found — skipping saved objects import"
fi
