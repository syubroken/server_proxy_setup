#!/usr/bin/env bash

# Read-only checks for an already-running Cloudflare WARP local proxy.
# This script never installs software or changes WARP, V2Ray, routes, or firewall rules.

set -u

PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
PROXY_PORT="${PROXY_PORT:-40000}"
PROXY_URL="socks5h://${PROXY_HOST}:${PROXY_PORT}"
TRACE_URL="https://www.cloudflare.com/cdn-cgi/trace"
OPENAI_URL="https://api.openai.com/v1/models"
LONG_URL="https://speed.cloudflare.com/__down?bytes=1048576"

pass_count=0
warn_count=0
fail_count=0

pass() {
    pass_count=$((pass_count + 1))
    printf '[PASS] %s\n' "$*"
}

warn() {
    warn_count=$((warn_count + 1))
    printf '[WARN] %s\n' "$*"
}

fail() {
    fail_count=$((fail_count + 1))
    printf '[FAIL] %s\n' "$*"
}

print_summary() {
    printf '\nSummary: PASS=%d WARN=%d FAIL=%d\n' \
        "$pass_count" "$warn_count" "$fail_count"
}

case "$PROXY_PORT" in
    ''|*[!0-9]*)
        printf '[FAIL] PROXY_PORT must be a number.\n' >&2
        exit 2
        ;;
esac

printf 'WARP local proxy read-only probe\n'
printf 'Target: %s\n' "$PROXY_URL"
printf 'No account token, cookie, or private key is read or sent.\n\n'

if ! command -v curl >/dev/null 2>&1; then
    fail 'curl is not installed.'
    print_summary
    exit 2
fi

if command -v warp-cli >/dev/null 2>&1; then
    version="$(warp-cli --version 2>/dev/null | head -n 1 || true)"
    if [[ -n "$version" ]]; then
        printf 'warp-cli: %s\n' "$version"
    else
        printf 'warp-cli: installed (version unavailable)\n'
    fi

    status="$(warp-cli status 2>/dev/null | head -n 5 || true)"
    if [[ -n "$status" ]]; then
        printf '%s\n' "$status"
    fi
else
    warn 'warp-cli is not installed. The old wgcf full-tunnel setup does not provide port 40000.'
fi

if command -v ss >/dev/null 2>&1; then
    if ss -lntH 2>/dev/null | awk -v suffix=":${PROXY_PORT}" '$4 ~ suffix "$" { found=1 } END { exit !found }'; then
        pass "A TCP listener exists on port ${PROXY_PORT}."
    else
        warn "No TCP listener was found on port ${PROXY_PORT}."
    fi
else
    warn 'ss is unavailable; curl will perform the connectivity check instead.'
fi

printf '\n1. Cloudflare trace through SOCKS5 (DNS is also resolved through the proxy)\n'
trace_output="$(curl \
    --proxy "$PROXY_URL" \
    --silent --show-error --fail \
    --connect-timeout 8 --max-time 20 \
    "$TRACE_URL" 2>&1)"
trace_rc=$?

if (( trace_rc != 0 )); then
    fail "The SOCKS5 proxy is unavailable: ${trace_output}"
    print_summary
    printf '\nNo settings were changed. Do not enable proxy mode on a stable production server only for this test.\n'
    exit 2
fi

trace_summary="$(printf '%s\n' "$trace_output" | grep -E '^(loc|colo|warp)=' || true)"
if [[ -n "$trace_summary" ]]; then
    printf '%s\n' "$trace_summary"
fi

if printf '%s\n' "$trace_output" | grep -q '^warp=on$'; then
    pass 'Traffic reached Cloudflare through WARP.'
else
    warn 'The proxy answered, but Cloudflare trace did not report warp=on.'
fi

printf '\n2. OpenAI HTTPS reachability through SOCKS5 (no API key is used)\n'
openai_metrics="$(curl \
    --proxy "$PROXY_URL" \
    --silent --show-error \
    --connect-timeout 8 --max-time 20 \
    --output /dev/null \
    --write-out 'HTTP=%{http_code} TIME=%{time_total}' \
    "$OPENAI_URL" 2>&1)"
openai_rc=$?

if (( openai_rc == 0 )); then
    printf '%s\n' "$openai_metrics"
    if [[ "$openai_metrics" == HTTP=401* ]]; then
        pass 'OpenAI was reached; HTTP 401 is expected without an API key.'
    elif [[ "$openai_metrics" == HTTP=000* ]]; then
        fail 'OpenAI did not return an HTTP response.'
    else
        warn 'OpenAI returned a response, but not the usual unauthenticated HTTP 401.'
    fi
else
    fail "OpenAI HTTPS failed: ${openai_metrics}"
fi

printf '\n3. Controlled request designed to last about 16 seconds\n'
printf 'This is an indicator for the documented 10-second local-proxy limit, not a WebSocket proof.\n'
long_metrics="$(curl \
    --proxy "$PROXY_URL" \
    --silent --show-error --location \
    --connect-timeout 8 --max-time 35 \
    --limit-rate 64K \
    --output /dev/null \
    --write-out ' HTTP=%{http_code} TIME=%{time_total}' \
    "$LONG_URL" 2>&1)"
long_rc=$?

printf '%s\n' "$long_metrics"
long_time="$(printf '%s\n' "$long_metrics" | sed -n 's/.*TIME=\([0-9.]*\).*/\1/p')"

if (( long_rc == 0 )); then
    if [[ -n "$long_time" ]] && awk -v t="$long_time" 'BEGIN { exit !(t >= 12) }'; then
        pass 'The controlled request stayed alive for more than 12 seconds.'
    else
        warn 'The request completed too quickly to test the documented timeout reliably.'
    fi
else
    if [[ -n "$long_time" ]] && awk -v t="$long_time" 'BEGIN { exit !(t >= 8 && t <= 13) }'; then
        warn 'The request ended near 10 seconds, consistent with the documented local-proxy limit.'
    else
        warn 'The long request failed, but its timing does not isolate the cause.'
    fi
fi

print_summary
printf '\nInterpretation:\n'
printf -- '- Passing HTTPS checks only proves basic proxy reachability.\n'
printf -- '- ChatGPT and Codex also use long-running secure WebSockets.\n'
printf -- '- A real 15-minute app session is still required to assess reconnect behavior.\n'
printf -- '- Keep the current full-tunnel setup unchanged unless testing on a disposable server.\n'

if (( fail_count > 0 )); then
    exit 1
fi

exit 0
