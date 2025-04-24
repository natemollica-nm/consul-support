#!/bin/sh

# POSIX-compliant script to collect Consul pprof profiles:
#   - heap
#   - profile (CPU)
#   - trace
#   - goroutine
# Uses CONSUL_HTTP_ADDR and CONSUL_HTTP_TOKEN if provided.

set -eu

# === Colors ===
RED=$(printf '\033[0;31m')
GRN=$(printf '\033[0;32m')
YLW=$(printf '\033[0;33m')
BLU=$(printf '\033[0;34m')
BOLD=$(printf '\033[1m')
RST=$(printf '\033[0m')

# === Input Defaults ===
CONSUL_ADDR="${1:-${CONSUL_HTTP_ADDR:-http://localhost:8500}}"
DURATION="${2:-30}"
TIMESTAMP=$(date +"%Y-%m-%dT%H-%M-%S")
OUTPUT_DIR="/tmp/consul-pprof-$TIMESTAMP"

# === Required Tools ===
for cmd in curl sed grep mktemp; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "${RED}❌ Missing required command: $cmd${RST}" >&2
    exit 1
  fi
done

mkdir -p "$OUTPUT_DIR"

# === Auth Header ===
CURL_AUTH_HEADER=""
if [ -n "${CONSUL_HTTP_TOKEN:-}" ]; then
  CURL_AUTH_HEADER="-H X-Consul-Token:${CONSUL_HTTP_TOKEN}"
  echo "${BLU}🔐 Using CONSUL_HTTP_TOKEN for authentication.${RST}"
fi

# === Curl Options ===
CURL_FLAGS="-sk --retry 3 --retry-delay 2 --max-time $((DURATION + 15)) --connect-timeout 10"

# === Preflight: Check Consul Reachability ===
if ! curl $CURL_FLAGS $CURL_AUTH_HEADER "$CONSUL_ADDR/v1/status/leader" >/dev/null 2>&1; then
  echo "${RED}❌ Unable to reach Consul agent at $CONSUL_ADDR${RST}" >&2
  exit 1
fi

# === Preflight: Check if debug is enabled ===
ENABLE_DEBUG=$(curl $CURL_FLAGS $CURL_AUTH_HEADER "$CONSUL_ADDR/v1/agent/self" \
  | sed -n 's/.*"EnableDebug":[ ]*\([^,}]*\).*/\1/p')

#if [ "$ENABLE_DEBUG" != "true" ]; then
#  echo "${YLW}⚠️  Debug mode is disabled (enable_debug=false)${RST}"
#fi

echo "      ==> ${GRN}🔍  Collecting pprof from:${RST} $CONSUL_ADDR"
echo "      ==> ${GRN}⏱️  Duration:${RST} ${DURATION}s"
echo "      ==> ${GRN}📁  Output Dir:${RST} $OUTPUT_DIR"
echo "      ==> ${GRN}🐞  Debug Enabled:${RST} ${BOLD}$( [ "$ENABLE_DEBUG" = true ] && echo "${GRN}${BOLD}true${RST}" || echo "${RED}${BOLD}⚠️  false${RST} ${YLW}(enable_debug=false)${RST}")"

# === Function: Validate profile file ===
validate_profile_file() {
  file="$1"
  label="$2"

  if [ ! -s "$file" ]; then
    echo "${RED}❌ $label profile is empty or missing: $file${RST}"
    echo "   ${YLW}Possible causes:${RST} network timeout, reverse proxy cutoff, system resource exhaustion"
    return 1
  fi

  if grep -qi 'stream timeout\|<html\|Usage:' "$file"; then
    echo "${YLW}⚠️  $label profile contains a potential error message${RST}"
    return 1
  fi

  echo "${GRN}✅  ${BOLD}$label${RST} profile validated"
  return 0
}

# === Profile types ===
profiles="heap profile trace goroutine"
urls="heap profile?seconds=$DURATION trace?seconds=$DURATION goroutine"
files="heap.prof profile.prof trace.out goroutine.prof"

i=1
for profile in $profiles; do
  url=$(echo "$urls" | cut -d' ' -f$i)
  file=$(echo "$files" | cut -d' ' -f$i)
  path="$OUTPUT_DIR/$file"

  echo "${BLU}📦 Fetching $profile profile...${RST}"
  if ! curl $CURL_FLAGS $CURL_AUTH_HEADER "$CONSUL_ADDR/debug/pprof/$url" -o "$path"; then
    echo "${RED}❌ Failed to fetch $profile profile${RST}"
    continue
  fi

  validate_profile_file "$path" "$profile" || echo "${YLW}⚠️ Skipping invalid $profile capture${RST}"
  i=$((i + 1))
done

echo "${GRN}🧪 Profile capture complete.${RST}"
echo "${GRN}📁 Results:${RST} $OUTPUT_DIR"