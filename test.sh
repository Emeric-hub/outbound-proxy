#!/bin/bash
# Proxy connectivity tests — runs against e2guardian:8080

PROXY="http://localhost:8080"
# Trust the generated MITM CA so HTTPS tests can verify the intercepted certs.
# Override with: CACERT=/path/to/ca.crt bash test.sh
CACERT="${CACERT:-$(dirname "$0")/e2guardian/certs/ca.crt}"
PASS=0
FAIL=0

ok()   { echo "[PASS] $1"; (( PASS++ )); }
fail() { echo "[FAIL] $1"; (( FAIL++ )); }

run() {
  local label="$1"; shift
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    --proxy "${PROXY}" \
    --cacert "${CACERT}" \
    --max-time 10 \
    "$@")
  echo -n "       HTTP ${http_code} — "
  if [[ "${http_code}" =~ ^[23] ]]; then
    ok "${label}"
  else
    fail "${label} (got ${http_code})"
  fi
}

run_blocked() {
  local label="$1"; shift
  local http_code body
  body=$(curl -s -w "\n%{http_code}" \
    --proxy "${PROXY}" \
    --cacert "${CACERT}" \
    --max-time 10 \
    "$@")
  http_code="${body##*$'\n'}"
  body="${body%$'\n'*}"
  echo -n "       HTTP ${http_code} — "
  # e2guardian v5 serves its block page with HTTP 200 (body contains "E2Guardian").
  # Also accept 403/302 for forward-compatibility.
  if [[ "${http_code}" == "403" || "${http_code}" == "302" ]] || \
     echo "${body}" | grep -qi "e2guardian"; then
    ok "${label} (correctly blocked)"
  else
    fail "${label} (expected block, got ${http_code})"
  fi
}

echo "========================================"
echo " Proxy: ${PROXY}"
echo " CA:    ${CACERT}"
echo "========================================"

echo ""
echo "── Basic HTTP ───────────────────────────"
run  "HTTP  example.com"      http://example.com
run  "HTTP  wikipedia.org"    http://en.wikipedia.org/wiki/Main_Page

echo ""
echo "── HTTPS (CONNECT + MITM) ───────────────"
run  "HTTPS example.com"      https://example.com
run  "HTTPS github.com"       https://github.com

echo ""
echo "── Proxy headers stripped ───────────────"
# Verify the proxy strips X-Forwarded-For / Via
response=$(curl -s --proxy "${PROXY}" --cacert "${CACERT}" --max-time 10 http://httpbin.org/get 2>/dev/null)
if echo "${response}" | grep -qi '"X-Forwarded-For"'; then
  fail "X-Forwarded-For still present in upstream request"
else
  ok  "X-Forwarded-For stripped"
fi
if echo "${response}" | grep -qi '"Via"'; then
  fail "Via header still present in upstream request"
else
  ok  "Via header stripped"
fi

echo ""
echo "── Block list ───────────────────────────"
run_blocked "linkadd.de blocked"       http://www.linkadd.de
run_blocked "doubleclick.net blocked"  http://doubleclick.net

echo ""
echo "── Exception list (always allowed) ──────"
run  "github.com allowed"     https://github.com
run  "wikipedia.org allowed"  http://wikipedia.org

echo ""
echo "========================================"
printf " Results: %d passed, %d failed\n" "${PASS}" "${FAIL}"
echo "========================================"

[[ ${FAIL} -eq 0 ]]
