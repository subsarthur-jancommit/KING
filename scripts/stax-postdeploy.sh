#!/usr/bin/env bash
#
# stax-postdeploy.sh — runtime guard for the STAX public surface.
#
# stax-preflight.sh runs BEFORE `docker compose up`, so it can only assert
# files and variables. It says so itself, and in two places it gives up and
# prints a curl for the operator to run by hand and eyeball:
#
#   check_proxy(): "Confirm registration is closed before trusting this: ...
#                   200 means anyone who finds the URL can register and run
#                   code on this host."
#   check_proxy(): "then verify: ... 401 is what you want. 200 means the
#                   gateway is open to the world."
#
# A check that depends on a human remembering to run it, and reading the
# number correctly, is not a check. Both of those are properties of the
# RUNNING instance, which is exactly what this script is for. Run it after
# every `up`, and on a timer if you like.
#
# What it catches that nothing else here does:
#
#   1. A public hostname that does not resolve at all. Found live on
#      2026-09-01: `flow.arject.co` returned NXDOMAIN from the authoritative
#      nameserver while every container was healthy and `gateway.arject.co`
#      served fine. Nothing in this repo would have noticed, because nothing
#      in this repo had ever asked DNS a question.
#   2. An open gateway. Found live on 2026-08-28 — an invalid key and no key
#      at all both returned 200 with a real completion. Preflight now blocks
#      REQUIRE_API_KEY=false, but that only proves what the file SAYS; this
#      proves what the gateway DOES.
#   3. Activepieces with registration still open on a public domain.
#   4. A webhook prefix that disagrees with the domain Caddy actually serves.
#      Webhook URLs are built from AP_FRONTEND_URL, so a mismatch does not
#      error anywhere — inbound webhooks are simply delivered to a hostname
#      nobody is listening on.
#
# Usage:
#   ./scripts/stax-postdeploy.sh                      # read domains from .env
#   ./scripts/stax-postdeploy.sh --gateway gw.x.co --flows flows.x.co
#   ./scripts/stax-postdeploy.sh --expect-ip 34.101.62.94
#   ./scripts/stax-postdeploy.sh --probe-signup       # see the warning below
#   ./scripts/stax-postdeploy.sh --self-test
#
# Exit codes: 0 = the deployed surface is correct, 1 = at least one blocking
# problem, 2 = usage error.

set -euo pipefail

readonly PLACEHOLDER_PUBLIC_DOMAIN='CHANGEME.example.com'

# Certificates are renewed by Caddy at 1/3 of remaining lifetime, so a 90-day
# Let's Encrypt cert should never fall below 30. Below 14 something is wrong
# with renewal and there is still a fortnight to fix it.
readonly TLS_WARN_DAYS=14

errors=0
warnings=0

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

fail() { red   "  FAIL  $*"; errors=$((errors + 1)); }
warn() { yellow "  WARN  $*"; warnings=$((warnings + 1)); }
pass() { green  "  ok    $*"; }

# "I could not find out" is not a pass. Three instruments in this repo used to
# answer zero when they could not read, and one of them stood in front of a
# 14-hour outage — see docs/integrations/reliability-plan.md and the same
# reasoning in monitor-deadman.sh. Unmeasurable counts as blocking.
unknown() { red "  ????  $*"; errors=$((errors + 1)); }

# Reads a variable's effective value: real environment first, then the given
# .env file. Same resolution order as stax-preflight.sh's lookup().
lookup() {
  local var="$1" env_file="${2:-}"
  if [ -n "${!var:-}" ]; then
    printf '%s' "${!var}"
    return
  fi
  [ -n "$env_file" ] && [ -f "$env_file" ] || return 0
  sed -n "s/^${var}=//p" "$env_file" | tail -1
}

# ---------------------------------------------------------------- DNS -------

# Returns the A records, and distinguishes the three outcomes that matter:
# resolved, authoritatively absent (NXDOMAIN), and could-not-ask. `getent`
# collapses the last two into one failure, so dig is required for a real
# answer; without it we report unmeasurable rather than guessing.
check_dns() {
  local host="$1" expect_ip="$2" label="$3"

  if ! command -v dig >/dev/null 2>&1; then
    unknown "$label: dig is not installed, so DNS cannot be checked (apt-get install dnsutils)."
    return
  fi

  local status ips
  status=$(dig +time=5 +tries=2 "$host" A 2>/dev/null | awk -F'status: ' '/status:/{split($2,a,",");print a[1];exit}')
  # `|| true` is load-bearing. Under `set -euo pipefail`, grep finding nothing
  # makes the whole pipeline exit 1, which killed this script silently at the
  # exact moment it had something to report: a name with no A record printed
  # the section header and then nothing at all, exit 1 with no reason given.
  # The one case the check exists for was the one case it could not report.
  ips=$(dig +time=5 +tries=2 +short "$host" A 2>/dev/null | grep -E '^[0-9.]+$' | tr '\n' ' ' | sed 's/ $//') || true

  case "$status" in
    NXDOMAIN)
      fail "$label: $host does not exist (NXDOMAIN). Nothing is served at this name."
      echo "         Every container can be healthy and this still be true. Add the A"
      echo "         record at your DNS provider, and check you are editing the zone"
      echo "         that the domain's nameservers actually answer from."
      return
      ;;
    NOERROR) : ;;
    '')
      unknown "$label: no answer from the resolver for $host — cannot tell whether it exists."
      return
      ;;
    *)
      fail "$label: DNS lookup for $host returned status $status."
      return
      ;;
  esac

  if [ -z "$ips" ]; then
    # NOERROR with no A record: the name exists (maybe as a CNAME to nothing,
    # or with only AAAA/TXT), but no IPv4 address means Caddy is unreachable.
    fail "$label: $host resolves but has no A record."
    return
  fi

  if [ -z "$expect_ip" ]; then
    pass "$label: $host resolves to $ips."
  elif printf '%s' " $ips " | grep -q " $expect_ip "; then
    pass "$label: $host resolves to $expect_ip as expected."
  else
    # A stale record is the quiet version of this failure: the name resolves,
    # TLS may even work at the other end, and you are testing someone else's
    # host while believing you are testing yours.
    fail "$label: $host resolves to $ips, not the expected $expect_ip."
  fi
}

# ---------------------------------------------------------------- TLS -------

check_tls() {
  local host="$1" label="$2"

  if ! command -v openssl >/dev/null 2>&1; then
    unknown "$label: openssl is not installed, so the certificate cannot be checked."
    return
  fi

  local cert
  if ! cert=$(printf '' | timeout 20 openssl s_client -servername "$host" -connect "$host:443" 2>/dev/null | openssl x509 -noout -subject -enddate -issuer 2>/dev/null); then
    unknown "$label: could not retrieve a certificate from $host:443."
    return
  fi
  [ -n "$cert" ] || { unknown "$label: empty certificate from $host:443."; return; }

  local enddate issuer end_epoch now_epoch days
  enddate=$(printf '%s' "$cert" | sed -n 's/^notAfter=//p')
  issuer=$(printf '%s' "$cert" | sed -n 's/^issuer=//p' | sed 's/.*CN *= *//;s/,.*//')

  if ! end_epoch=$(date -d "$enddate" +%s 2>/dev/null); then
    unknown "$label: certificate expiry '$enddate' could not be parsed."
    return
  fi
  now_epoch=$(date +%s)
  days=$(( (end_epoch - now_epoch) / 86400 ))

  if [ "$days" -lt 0 ]; then
    fail "$label: the certificate for $host EXPIRED $(( -days )) day(s) ago."
  elif [ "$days" -lt "$TLS_WARN_DAYS" ]; then
    # Caddy renews at 1/3 of lifetime. Reaching this window means renewal has
    # been failing silently for weeks, usually because port 80 got closed.
    warn "$label: the certificate for $host expires in $days day(s) — renewal is not working."
    echo "         Caddy renews at 1/3 of remaining lifetime, so this should never"
    echo "         happen. Check that port 80 is still open for ACME HTTP-01."
  else
    pass "$label: TLS valid for $days more day(s), issued by ${issuer:-unknown}."
  fi
}

# --------------------------------------------------------- HTTP helpers -----

# Prints the status code, or the empty string if the request could not be
# made at all. Callers must treat empty as unmeasurable, never as a failure
# of the assertion they were testing.
http_code() {
  local url="$1"
  shift
  curl -s -o /dev/null -w '%{http_code}' -m 25 "$@" "$url" 2>/dev/null || printf ''
}

# ------------------------------------------------------------ gateway ------

check_gateway() {
  local host="$1"
  echo "gateway: $host (OmniRoute)"

  local health
  health=$(http_code "https://$host/healthz")
  case "$health" in
    200) pass "/healthz returns 200." ;;
    '' | 000) unknown "could not reach https://$host/healthz at all." ;;
    *) fail "/healthz returns $health — the gateway is not serving." ;;
  esac

  # The open-gateway check. This is the one that matters: preflight can prove
  # REQUIRE_API_KEY=true is written in omniroute/.env, but only a real
  # unauthenticated request proves the running process honours it. On
  # 2026-08-28 it did not, and the file was not what was wrong.
  #
  # A completions POST is used rather than GET /v1/models because that is the
  # endpoint that actually spends money, and because some builds leave the
  # model list readable on purpose.
  local unauth
  unauth=$(http_code "https://$host/v1/chat/completions" \
    -X POST -H 'Content-Type: application/json' \
    -d '{"model":"probe/none","messages":[]}')

  case "$unauth" in
    401 | 403)
      pass "unauthenticated /v1/chat/completions is rejected ($unauth)."
      ;;
    '' | 000)
      unknown "could not probe /v1/chat/completions — cannot prove the gateway is closed."
      ;;
    200)
      fail "THE GATEWAY IS OPEN. Unauthenticated /v1/chat/completions returned 200."
      echo "         Anyone who knows this hostname can spend your provider credit."
      echo "         Set REQUIRE_API_KEY=true in omniroute/.env and restart the gateway,"
      echo "         then run this again. Do not leave it up in the meantime."
      ;;
    *)
      # 4xx that is not 401/403 (a 400 for the deliberately invalid body, say)
      # does not prove authentication is enforced — the request may have been
      # rejected before any auth check ran.
      warn "unauthenticated /v1/chat/completions returned $unauth, which neither proves nor disproves auth."
      echo "         Expected 401 or 403. Check by hand before trusting this deployment."
      ;;
  esac
}

# ----------------------------------------------------------- activepieces ---

check_flows() {
  local host="$1" probe_signup="$2"
  echo "flows: $host (Activepieces)"

  local flags_json
  flags_json=$(curl -sf -m 25 "https://$host/api/v1/flags" 2>/dev/null || printf '')

  if [ -z "$flags_json" ]; then
    unknown "could not read https://$host/api/v1/flags — Activepieces is not answering."
    return
  fi
  pass "/api/v1/flags is served."

  # Read the values we care about with python3 rather than grep: the flags
  # payload is a flat JSON object but the values include URLs with slashes
  # and braces, and a regex over that is how you get a confident wrong answer.
  local version edition webhook_prefix user_created
  read -r version edition webhook_prefix user_created <<<"$(printf '%s' "$flags_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
def g(k):
    v = d.get(k, "-")
    return "-" if v in ("", None) else str(v).replace(" ", "_")
print(g("CURRENT_VERSION"), g("EDITION"), g("WEBHOOK_URL_PREFIX"), g("USER_CREATED"))
' 2>/dev/null || printf '- - - -')"

  if [ "$version" = "-" ]; then
    unknown "could not parse the flags payload from $host."
    return
  fi
  pass "Activepieces $version, edition $edition."

  # A webhook prefix pointing somewhere other than the domain Caddy serves is
  # the silent failure this catches: AP builds every webhook URL it hands out
  # from AP_FRONTEND_URL, so if that is stale, the URLs you paste into Slack
  # or GitHub are syntactically fine and delivered to nobody.
  case "$webhook_prefix" in
    "https://$host/api/v1/webhooks")
      pass "webhook prefix matches the served domain."
      ;;
    -)
      warn "the instance did not report a webhook prefix."
      ;;
    *localhost* | *127.0.0.1*)
      fail "webhook prefix is $webhook_prefix — inbound webhooks will never arrive."
      echo "         Set AP_FRONTEND_URL=https://$host in activepieces/.env and restart."
      ;;
    *)
      fail "webhook prefix is $webhook_prefix but this instance is served at https://$host."
      echo "         Webhook URLs are built from AP_FRONTEND_URL, so every URL this"
      echo "         instance hands out points at the wrong host. Nothing will error;"
      echo "         the deliveries simply go somewhere you are not listening."
      ;;
  esac

  # Registration. USER_CREATED is what the running instance reports about
  # itself, and in CE the first account closes signup — so this is the
  # read-only way to answer the question preflight told the operator to
  # answer with a POST. It is evidence, not proof: only --probe-signup
  # actually exercises the endpoint.
  case "$user_created" in
    True | true)
      pass "an account already exists (USER_CREATED=$user_created) — signup should be closed."
      ;;
    False | false)
      fail "USER_CREATED=$user_created — no account exists yet, so registration is OPEN."
      echo "         Anyone who finds this URL can create the admin account and run"
      echo "         code on this host. Create your account now, or take the domain"
      echo "         down until you do."
      ;;
    *)
      warn "USER_CREATED is '$user_created' — cannot tell whether registration is closed."
      ;;
  esac

  if [ "$probe_signup" -eq 1 ]; then
    # Deliberately opt-in. If registration IS open, this call SUCCEEDS and
    # leaves a real account behind — which is precisely why it is not the
    # default, and why the failure message tells you to go delete it.
    local code
    code=$(http_code "https://$host/api/v1/authentication/sign-up" \
      -X POST -H 'Content-Type: application/json' \
      -d '{"firstName":"postdeploy","lastName":"probe","email":"probe@example.invalid","password":"Pr0be-Test-99xz","trackEvents":false,"newsLetter":false}')
    case "$code" in
      403) pass "sign-up probe rejected (403) — registration is closed." ;;
      '' | 000) unknown "sign-up probe could not be sent." ;;
      200 | 201)
        fail "SIGN-UP IS OPEN — the probe created an account (probe@example.invalid)."
        echo "         Delete that account now, then close registration."
        ;;
      *) warn "sign-up probe returned $code; expected 403." ;;
    esac
  fi
}

# ------------------------------------------------------------ containers ----

check_containers() {
  echo "containers"

  # Three distinct situations, and only one of them is a problem:
  #
  #   no docker binary        -> not the deploy host. Skip.
  #   binary but no daemon    -> not the deploy host either. Skip.
  #   daemon, but ps errors   -> this IS the deploy host and it will not answer.
  #
  # The first cut of this checked only for the binary, and then reported a
  # blocking failure from a machine that was never running the containers —
  # every public check green, exit 1. A guard that fires where there is
  # nothing to guard trains you to ignore it.
  if ! command -v docker >/dev/null 2>&1; then
    echo "         docker is not on this host — skipping local container checks."
    echo "         (The checks above test the public surface and do not need it.)"
    return
  fi

  if ! docker info >/dev/null 2>&1; then
    echo "         the Docker daemon is not reachable from here — skipping local"
    echo "         container checks. Run this on the deploy host to include them."
    return
  fi

  local ps_out
  # 2>&1 rather than 2>/dev/null: if the daemon answered `docker info` but
  # cannot answer this, the message is the whole diagnosis.
  if ! ps_out=$(docker compose ps --format '{{.Name}}\t{{.State}}\t{{.Status}}' 2>&1); then
    unknown "docker compose ps failed: $(printf '%s' "$ps_out" | tr '\n' ' ' | cut -c1-160)"
    return
  fi

  if [ -z "$ps_out" ]; then
    fail "no containers are running for this compose project."
    return
  fi

  local name state status
  while IFS=$'\t' read -r name state status; do
    [ -n "$name" ] || continue
    case "$status" in
      *unhealthy*)  fail "$name is unhealthy ($status)." ;;
      *Restarting*) fail "$name is restarting ($status)." ;;
      *"health: starting"*) warn "$name is still starting ($status)." ;;
      *)
        if [ "$state" = "running" ]; then
          pass "$name is running ($status)."
        else
          fail "$name is $state ($status)."
        fi
        ;;
    esac
  done <<<"$ps_out"
}

# ------------------------------------------------------------- self test ----

self_test() {
  echo "stax-postdeploy self-test"
  echo
  local t_errors=0
  t() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
      green "  ok    $desc"
    else
      red   "  FAIL  $desc (expected '$expected', got '$actual')"
      t_errors=$((t_errors + 1))
    fi
  }

  # lookup(): environment beats file, file is read when the env is unset.
  local tmp
  tmp=$(mktemp)
  printf 'FOO=from_file\nBAR=x\n' > "$tmp"
  t "lookup reads the env file"        "from_file" "$(lookup FOO "$tmp")"
  t "lookup prefers the environment"   "from_env"  "$(FOO=from_env lookup FOO "$tmp")"
  t "lookup on a missing var is empty" ""          "$(lookup NOPE "$tmp")"
  t "lookup on a missing file is empty" ""         "$(lookup FOO /nonexistent)"
  rm -f "$tmp"

  # The counters must actually count, because the exit code is built from
  # them and a silent miscount would turn a red deploy green.
  local saved_e=$errors saved_w=$warnings
  errors=0; warnings=0
  fail "synthetic" >/dev/null; warn "synthetic" >/dev/null; pass "synthetic" >/dev/null
  t "fail increments errors"    "1" "$errors"
  t "warn increments warnings"  "1" "$warnings"
  errors=0
  unknown "synthetic" >/dev/null
  t "unknown counts as blocking" "1" "$errors"
  errors=$saved_e; warnings=$saved_w

  # Regression pin for the bug that made check_dns die silently on exactly
  # the input it exists to catch. Under `set -euo pipefail` an assignment
  # whose pipeline ends in a no-match grep exits 1 and takes the script with
  # it. This asserts the guarded form survives; if someone drops the
  # `|| true`, this fails here instead of in production at 3am.
  local survived=no
  probe=$(printf 'nothing\n' | grep -E '^[0-9.]+$' | tr '\n' ' ') || true
  survived=yes
  t "a no-match grep pipeline does not abort the script" "yes" "$survived"
  t "and yields an empty value"                          ""    "$probe"

  echo
  if [ "$t_errors" -gt 0 ]; then
    red "$t_errors self-test failure(s)."
    return 1
  fi
  green "self-test passed."
  return 0
}

# ------------------------------------------------------------------ main ----

main() {
  local gateway='' flows='' expect_ip='' probe_signup=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --self-test)   cd "$(dirname "$0")/.."; self_test; exit $? ;;
      --gateway)     gateway="${2:-}"; shift 2 || exit 2 ;;
      --flows)       flows="${2:-}";   shift 2 || exit 2 ;;
      --expect-ip)   expect_ip="${2:-}"; shift 2 || exit 2 ;;
      --probe-signup) probe_signup=1; shift ;;
      -h|--help)
        sed -n '2,45p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'
        exit 0
        ;;
      *) echo "unknown argument '$1' (try --help)" >&2; exit 2 ;;
    esac
  done

  cd "$(dirname "$0")/.."

  [ -n "$gateway" ] || gateway=$(lookup OMNIROUTE_PUBLIC_DOMAIN .env)
  [ -n "$flows" ]   || flows=$(lookup ACTIVEPIECES_PUBLIC_DOMAIN .env)

  if [ -z "$gateway" ] && [ -z "$flows" ]; then
    echo "Nothing to check: neither OMNIROUTE_PUBLIC_DOMAIN nor" >&2
    echo "ACTIVEPIECES_PUBLIC_DOMAIN is set, and neither --gateway nor" >&2
    echo "--flows was given. See --help." >&2
    exit 2
  fi

  if [ "$gateway" = "$PLACEHOLDER_PUBLIC_DOMAIN" ]; then
    echo "OMNIROUTE_PUBLIC_DOMAIN is still the placeholder; run stax-preflight.sh first." >&2
    exit 2
  fi

  echo "STAX post-deploy — checking the surface that is actually served"
  echo

  if [ -n "$gateway" ]; then
    echo "dns/tls: $gateway"
    check_dns "$gateway" "$expect_ip" "gateway"
    check_tls "$gateway" "gateway"
    echo
    check_gateway "$gateway"
    echo
  fi

  if [ -n "$flows" ]; then
    echo "dns/tls: $flows"
    check_dns "$flows" "$expect_ip" "flows"
    check_tls "$flows" "flows"
    echo
    check_flows "$flows" "$probe_signup"
    echo
  fi

  check_containers
  echo

  if [ "$errors" -gt 0 ]; then
    red "$errors blocking problem(s), $warnings warning(s). The deployment is not correct."
    exit 1
  fi
  if [ "$warnings" -gt 0 ]; then
    yellow "$warnings warning(s), no blocking problems."
    exit 0
  fi
  green "All post-deploy checks passed."
}

main "$@"
