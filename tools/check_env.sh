#!/usr/bin/env bash
# Read-only environment inventory for the Strata -> LM Studio bridge.
#
# Safety contract (ground rules):
#   * This script only READS. It never kills, signals, renices, or writes to any
#     Strata process, nor to ~/.strata/** or ~/.local/share/strata/**.
#   * It talks to Strata's GATEWAY only (127.0.0.1:47831), never the engine (18500).
#   * The Strata serving key is read from ~/.strata/data/state.json at runtime and is
#     NEVER printed, logged, or exported. Only its length is reported.
#
# Exit codes: 0 = baseline healthy, 1 = Strata gateway / expected model missing (abort),
#             2 = LM Studio side degraded (warning, may still proceed).
set -uo pipefail

STRATA_BASE="${STRATA_BASE:-http://127.0.0.1:47831/v1}"
LMS_BASE="${LMS_BASE:-http://127.0.0.1:1234}"
EXPECTED_MODEL="${EXPECTED_MODEL:-iq3_s}"
STATE_JSON="${STATE_JSON:-$HOME/.strata/data/state.json}"

FAIL=0
WARN=0

say()  { printf '%s\n' "$*"; }
head2() { printf '\n== %s ==\n' "$*"; }
bad()  { printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf 'WARN: %s\n' "$*"; WARN=$((WARN+1)); }
ok()   { printf 'ok:   %s\n' "$*"; }

# ---------------------------------------------------------------- secrets ----
head2 "Secrets (values never printed)"
if [[ -r "$STATE_JSON" ]]; then
  KEY_LEN=$(python3 - "$STATE_JSON" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    k = (d.get("serving") or {}).get("apiKey") or ""
    print(len(k))
except Exception as e:
    print("ERR", file=sys.stderr)
    print(0)
PY
)
  if [[ "${KEY_LEN:-0}" -gt 0 ]]; then
    ok "Strata serving key present in $STATE_JSON (length $KEY_LEN, value withheld)"
  else
    bad "Could not read serving.apiKey from $STATE_JSON"
  fi
else
  bad "$STATE_JSON not readable"
fi

# ------------------------------------------------------------- processes ----
head2 "Processes (read-only listing)"
if pgrep -af 'strata' >/dev/null 2>&1; then
  pgrep -af 'strata' | sed -e 's/\(apiKey=\|api_key=\|Bearer \)[^ ]*/\1<redacted>/g'
else
  bad "no process matching 'strata' found"
fi
if pgrep -af 'lm-studio|lmlink-connector' >/dev/null 2>&1; then
  pgrep -af 'lm-studio|lmlink-connector'
else
  warn "no lm-studio / lmlink-connector process found"
fi

# ----------------------------------------------------------------- ports ----
head2 "Listening sockets (loopback + connector)"
ss -ltnp 2>/dev/null | awk 'NR==1 || /127\.0\.0\.1|::1|0\.0\.0\.0/' | head -40

# ------------------------------------------------------- strata gateway ----
head2 "Strata gateway: $STRATA_BASE"
fetch_strata() {
  # $1 = path under base; key supplied from state.json, never echoed
  local path="$1"
  local key
  key=$(python3 - "$STATE_JSON" <<'PY'
import json, sys
print((json.load(open(sys.argv[1])).get("serving") or {}).get("apiKey") or "")
PY
)
  # key delivered through curl's stdin config so it never appears in argv/ps
  printf 'header = "Authorization: Bearer %s"\n' "$key" |
    curl -sS --max-time 10 --config - "${STRATA_BASE%/}/${path}"
}

MODELS_JSON=$(fetch_strata "models")
if [[ -z "$MODELS_JSON" ]]; then
  bad "Strata /v1/models returned nothing (gateway down or unreachable)"
else
  say "$MODELS_JSON" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print("FAIL: /v1/models did not return JSON:", raw[:200]); sys.exit(1)
if "error" in d:
    print("FAIL: gateway error:", str(d["error"])[:200]); sys.exit(1)
ids = [m.get("id") for m in d.get("data", [])]
print("ok:   model ids:", ids)
' || FAIL=$((FAIL+1))
  if printf '%s' "$MODELS_JSON" | grep -q "\"$EXPECTED_MODEL\""; then
    ok "expected model '$EXPECTED_MODEL' is loaded"
  else
    bad "expected model '$EXPECTED_MODEL' is NOT in the gateway model list - ABORT"
  fi
fi

# ------------------------------------------------------- lm studio rest ----
head2 "LM Studio REST: $LMS_BASE"
if curl -sS --max-time 5 -o /dev/null -w 'ok:   GET /v1/models -> HTTP %{http_code}\n' "$LMS_BASE/v1/models" 2>/dev/null; then
  :
else
  warn "LM Studio REST not answering on $LMS_BASE (start the app / enable the API)"
  WARN=$((WARN+1))
fi
LMS_LOADED=$(curl -sS --max-time 5 "$LMS_BASE/api/v1/models" 2>/dev/null || true)
if [[ -n "$LMS_LOADED" ]]; then
  printf '%s' "$LMS_LOADED" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    print("WARN: /api/v1/models not JSON"); sys.exit(0)
items = d.get("data", d if isinstance(d, list) else [])
for m in items:
    if isinstance(m, dict):
        print("      -", m.get("model"), "| loaded:", m.get("loaded"), "| format:", m.get("format"))
' || warn "could not parse LM Studio model list"
fi

head2 "lms CLI status"
LMS_BIN="${LMS_BIN:-$HOME/.lmstudio/bin/lms}"
if [[ -x "$LMS_BIN" ]]; then
  "$LMS_BIN" status 2>&1 | head -20 || warn "lms status failed"
  say "-- lms link status --"
  "$LMS_BIN" link status 2>&1 | head -30 || warn "lms link status failed"
else
  warn "lms CLI not found at $LMS_BIN"
fi

# ------------------------------------------------------------------- ram ----
head2 "Memory headroom (must stay > 0 before any extra model load)"
free -h
AVAIL_KB=$(awk '/^MemAvailable/ {print $2}' /proc/meminfo)
if [[ "${AVAIL_KB:-0}" -lt 4194304 ]]; then
  warn "less than 4 GiB available - do NOT attempt to load a second model copy"
else
  ok "at least 4 GiB available"
fi

# ------------------------------------------------------ plugin inventory ----
head2 "Installed plugins (LM Studio + Bionic)"
for base in "$HOME/.lmstudio/extensions/plugins" "$HOME/.lmstudio/apps/bionic/extensions/plugins"; do
  say "path: $base"
  if [[ -d "$base" ]]; then
    find "$base" -maxdepth 3 -name manifest.json -print 2>/dev/null | sed "s|$HOME|~|"
  else
    say "      (absent)"
  fi
done

# ----------------------------------------------------------- plugin stdout --
head2 "Where does plugin stdout go? (server-logs scan, read-only)"
LOGDIR="$HOME/.lmstudio/server-logs"
if [[ -d "$LOGDIR" ]]; then
  NFILES=$(find "$LOGDIR" -type f | wc -l)
  say "log files: $NFILES file(s) (recursive; stored in month folders), newest:"
  find "$LOGDIR" -type f -printf '%TY-%Tm-%Td %TH:%TM  %s bytes  %p\n' 2>/dev/null | sort -r | head -6
  # Look for a bundled plugin's per-chunk marker. Never print matched content.
  HITS=$(grep -rl "Received chunk" "$LOGDIR" 2>/dev/null | wc -l)
  if [[ "$HITS" -gt 0 ]]; then
    warn "a bundled plugin's chunk logs ARE persisted under server-logs ($HITS file(s))"
  else
    ok "no 'Received chunk' marker anywhere under server-logs -> plugin stdout is NOT persisted there"
  fi
  # Any other place plugin output could land?
  for extra in "$HOME/.lmstudio/logs" "$HOME/.lmstudio/.internal/logs" "$HOME/.config/lmstudio"; do
    [[ -d "$extra" ]] && say "also present: ${extra/#$HOME/~} ($(find "$extra" -type f 2>/dev/null | wc -l) file(s))"
  done
else
  say "no $LOGDIR directory"
fi

# ------------------------------------------------------------- verdict -----
head2 "Verdict"
say "failures: $FAIL   warnings: $WARN"
if [[ $FAIL -gt 0 ]]; then
  say "ABORT: Strata gateway / expected model not confirmed. Do not proceed."
  exit 1
fi
if [[ $WARN -gt 0 ]]; then
  say "Baseline usable, but warnings above need attention before proceeding."
  exit 0
fi
say "Baseline healthy."
exit 0
