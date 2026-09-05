#!/usr/bin/env bash
#
# stax-preflight.sh — deploy guard for the STAX profiles.
#
# Why this exists rather than compose-native `${VAR:?err}` guards: Compose
# interpolates required variables across the ENTIRE merged model before it
# filters services by profile. A `${OH_AGENT_CANVAS_SECRET_KEY:?set me}` in
# the openhands service therefore breaks `docker compose --profile base up`
# for someone who never asked for openhands. Verified directly against
# Docker Compose v5.1.1:
#
#   services: {always-on: {...}, gated: {environment: [X=${MUST:?}], profiles: [gated]}}
#   $ docker compose config --services      # no profile selected
#   error while interpolating services.gated.environment.[]: required
#   variable MUST is missing a value
#
# So the checks that must be profile-scoped live here instead, where scoping
# is trivial. Run this before `docker compose ... up` on any host that is not
# your laptop.
#
# Usage:
#   ./scripts/stax-preflight.sh base                       # OmniRoute only
#   ./scripts/stax-preflight.sh base agent-sidecar
#   ./scripts/stax-preflight.sh base openhands observability
#   ./scripts/stax-preflight.sh base proxy                 # public HTTPS deploy
#   ./scripts/stax-preflight.sh base proxy workflow        # + Activepieces
#   ./scripts/stax-preflight.sh base tracing               # + traces to Langfuse
#   ./scripts/stax-preflight.sh codegraph                  # graphify MCP server
#   ./scripts/stax-preflight.sh localmodel                 # Ollama behind OmniRoute
#   ./scripts/stax-preflight.sh --self-test                # verify this script
#
# Exit codes: 0 = safe to deploy, 1 = at least one blocking problem.

set -euo pipefail

readonly PLACEHOLDER_OH_SECRET='CHANGEME-openssl-rand-base64-32'
readonly PLACEHOLDER_PUBLIC_DOMAIN='CHANGEME.example.com'

# Upstream Langfuse ships these as literal defaults with a `# CHANGEME`
# comment; they are published values, not secrets.
readonly PLACEHOLDER_NEXTAUTH='mysecret'
readonly PLACEHOLDER_MINIO_PASSWORD='miniosecret'

errors=0
warnings=0

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

fail() { red   "  FAIL  $*"; errors=$((errors + 1)); }
warn() { yellow "  WARN  $*"; warnings=$((warnings + 1)); }
pass() { green  "  ok    $*"; }

# Reads a variable's effective value: real environment first, then the given
# .env file. Mirrors how Compose itself resolves ${VAR:-default}.
lookup() {
  local var="$1" env_file="${2:-}"
  if [ -n "${!var:-}" ]; then
    printf '%s' "${!var}"
    return
  fi
  if [ -n "$env_file" ] && [ -f "$env_file" ]; then
    # Last assignment wins, matching dotenv semantics. Only strips a trailing
    # newline — an inline `# comment` is part of the value for Compose too,
    # which is exactly the bug that bit observability/.env.example earlier.
    sed -n "s/^${var}=//p" "$env_file" | tail -n 1
  fi
}

check_secret() {
  local label="$1" value="$2" placeholder="$3" min_len="${4:-16}"
  if [ -z "$value" ]; then
    fail "$label is unset — the compose placeholder would be used instead."
    return
  fi
  if [ "$value" = "$placeholder" ]; then
    fail "$label is still the published placeholder value. Anyone reading this repo knows it."
    return
  fi
  if [ "${#value}" -lt "$min_len" ]; then
    fail "$label is only ${#value} characters; expected at least $min_len."
    return
  fi
  pass "$label is set to a non-placeholder value."
}

# A bind host is safe if it is loopback. Anything else publishes the port on
# an interface reachable from outside the machine.
check_bind_host() {
  local label="$1" value="$2" guidance="$3"
  case "${value:-127.0.0.1}" in
    127.0.0.1 | ::1 | localhost)
      pass "$label stays on loopback."
      ;;
    *)
      warn "$label is ${value} — reachable off-host. $guidance"
      ;;
  esac
}

check_base() {
  echo "profile: base (OmniRoute)"
  if [ ! -f omniroute/.env ]; then
    fail "omniroute/.env is missing. Copy omniroute/.env.example and fill it in."
    return
  fi
  local jwt api_key initial
  jwt=$(lookup JWT_SECRET omniroute/.env)
  api_key=$(lookup API_KEY_SECRET omniroute/.env)
  initial=$(lookup INITIAL_PASSWORD omniroute/.env)
  # Compared against omniroute/.env.example so we flag values copied over
  # verbatim, without hardcoding OmniRoute's placeholders here (they belong to
  # the vendored subtree and may change on the next `git subtree pull`).
  check_secret "JWT_SECRET" "$jwt" "$(lookup JWT_SECRET omniroute/.env.example)" 32
  check_secret "API_KEY_SECRET" "$api_key" "$(lookup API_KEY_SECRET omniroute/.env.example)" 32
  check_secret "INITIAL_PASSWORD" "$initial" "$(lookup INITIAL_PASSWORD omniroute/.env.example)" 12

  # OmniRoute keeps everything — API keys, provider credentials, settings — in
  # SQLite under /app/data, bind-mounted from omniroute/data. The container
  # runs as uid 1000, and Docker creates a missing bind-mount source as
  # root:root, so the very first `up` on a fresh host leaves a directory the
  # app cannot write.
  #
  # It does not crash, and on the version deployed 2026-08-28 it did not even
  # log EACCES — grepping the logs for it returned zero. Everything works
  # until the container restarts, at which point every key silently vanishes.
  # That is exactly how a real deployment lost its API key here: created it,
  # used it, recreated the container for an unrelated config change, and the
  # key was gone with no error anywhere.
  local data_uid
  if [ ! -d omniroute/data ]; then
    warn "omniroute/data does not exist yet; Docker will create it as root and OmniRoute (uid 1000) will not be able to write."
    echo "         Create it first:  mkdir -p omniroute/data && sudo chown -R 1000:1000 omniroute/data"
  elif data_uid=$(stat -c '%u' omniroute/data 2>/dev/null) && [ -n "$data_uid" ]; then
    if [ "$data_uid" = "1000" ]; then
      pass "omniroute/data is owned by uid 1000 — OmniRoute can persist its database."
    else
      fail "omniroute/data is owned by uid $data_uid but OmniRoute runs as uid 1000. Its SQLite writes fail SILENTLY and every API key is lost on restart."
      echo "         Fix:  sudo chown -R 1000:1000 omniroute/data"
      echo "         Then prove it survives a restart:"
      echo "           docker compose --profile base restart omniroute-base"
      echo "           # log in, list keys — a key created before the restart must still be there"
    fi
  fi
}

# Split out of check_agent_sidecar so the self-test can drive all four
# combinations directly. The agent's tools need BOTH an allowlist and a
# manage-scoped key, and having only one is silent in the worst way: the agent
# runs, answers from training data, and sounds exactly like one that searched.
# /healthz reports it as agent_tools_active:false — but that is after the
# deploy, and this runs before it.
check_agent_tools_wiring() {
  local mcp_key="$1" tool_list="$2" lowered
  lowered=$(printf '%s' "$tool_list" | tr '[:upper:]' '[:lower:]')

  if [ -n "$mcp_key" ]; then
    if [ "$lowered" = "none" ]; then
      warn "OMNIROUTE_MCP_API_KEY is set but AGENT_SIDECAR_AGENT_TOOLS=none — a manage-scoped key is provisioned and nothing uses it."
    else
      pass "OMNIROUTE_MCP_API_KEY is set; the agent can load its tool allowlist."
    fi
    warn "OMNIROUTE_MCP_API_KEY carries manage scope — the most privileged credential in this stack. Rotate it with the rest."
    return
  fi

  if [ "$lowered" = "none" ]; then
    pass "No MCP key and AGENT_SIDECAR_AGENT_TOOLS=none — the agent is deliberately toolless."
  else
    warn "OMNIROUTE_MCP_API_KEY is unset, so the agent starts with NO tools and will not fail — it answers from training data instead. Set the key, or set AGENT_SIDECAR_AGENT_TOOLS=none to say you meant it."
  fi
}

check_agent_sidecar() {
  echo "profile: agent-sidecar"
  local executor
  executor=$(lookup AGENT_SIDECAR_EXECUTOR agent-sidecar/.env)
  executor="${executor:-local}"
  case "$executor" in
    local)
      warn "AGENT_SIDECAR_EXECUTOR=local runs model-generated Python inside the sidecar container."
      echo "         This is the intended setting while tasks come from an operator on the CLI."
      echo "         If task text ever arrives from outside your shell, move to e2b/modal/blaxel"
      echo "         (not docker — see below)."
      ;;
    docker)
      # smolagents' DockerExecutor uses docker.from_env(), so inside a
      # container this needs the host Docker socket mounted into the sidecar
      # — root-equivalent host access granted to the service that runs
      # model-written code by design. Off-host sandboxes avoid that entirely.
      warn "AGENT_SIDECAR_EXECUTOR=docker needs the host Docker socket mounted into the sidecar."
      echo "         That is root-equivalent host access for the service that executes"
      echo "         model-generated code. Prefer e2b/modal/blaxel, which need no local daemon."
      ;;
    e2b | modal | blaxel)
      pass "AGENT_SIDECAR_EXECUTOR=$executor sandboxes execution off this host."
      ;;
    *)
      fail "AGENT_SIDECAR_EXECUTOR=$executor is not a value smolagents accepts."
      ;;
  esac

  local key
  key=$(lookup OMNIROUTE_API_KEY agent-sidecar/.env)
  if [ -z "$key" ]; then
    warn "OMNIROUTE_API_KEY is unset; the sidecar will only reach keyless models."
  else
    pass "OMNIROUTE_API_KEY is set."
  fi
  local mcp_key tool_list
  mcp_key=$(lookup OMNIROUTE_MCP_API_KEY agent-sidecar/.env)
  tool_list=$(lookup AGENT_SIDECAR_AGENT_TOOLS agent-sidecar/.env)
  [ -n "$tool_list" ] || tool_list=$(lookup AGENT_SIDECAR_AGENT_TOOLS .env)
  check_agent_tools_wiring "$mcp_key" "$tool_list"
}


check_openhands() {
  echo "profile: openhands"
  check_secret "OH_AGENT_CANVAS_SECRET_KEY" \
    "$(lookup OH_AGENT_CANVAS_SECRET_KEY)" "$PLACEHOLDER_OH_SECRET" 32
  check_bind_host "OPENHANDS_CANVAS_BIND_HOST" "$(lookup OPENHANDS_CANVAS_BIND_HOST)" \
    "This panel is not known to authenticate by default — put TLS + auth in front of it."

  if grep -qE '^[[:space:]]*-[[:space:]]*/var/run/docker\.sock' docker-compose.yml; then
    warn "The Docker socket is mounted into openhands-agent-canvas."
    echo "         That is root-equivalent access to this host. Intentional only if you"
    echo "         decided agent sandboxing is worth it — see docs/integrations/vps-hardening.md."
  else
    pass "Docker socket is not mounted (agents run in-container, no host escalation path)."
  fi
}

check_agent_sidecar_http() {
  echo "profile: agent-sidecar-http"
  # Same image, same runners, same executor decision — so reuse that profile's
  # checks rather than drifting a second copy of them.
  check_agent_sidecar

  # What is genuinely different: this one is long-lived and publishes a port,
  # and it has no authentication of its own. Its whole safety argument is that
  # only things already inside the compose network can reach it.
  check_bind_host "AGENT_SIDECAR_HTTP_BIND_HOST" "$(lookup AGENT_SIDECAR_HTTP_BIND_HOST)" \
    "This endpoint has NO authentication and runs model-generated code. Do not expose it."
}

check_workflow() {
  echo "profile: workflow (Activepieces)"
  if [ ! -f activepieces/.env ]; then
    fail "activepieces/.env is missing. Copy activepieces/.env.example and fill it in."
    return
  fi

  # Lengths match what Activepieces documents: `openssl rand -hex 16` for the
  # encryption key (32 hex chars) and `openssl rand -hex 32` for the JWT
  # secret (64). The encryption key is length-sensitive upstream, not just
  # strength-sensitive — a wrong length fails at boot rather than degrading.
  local enc
  enc=$(lookup AP_ENCRYPTION_KEY activepieces/.env)
  check_secret "AP_ENCRYPTION_KEY" "$enc" '' 32
  if [ -n "$enc" ] && [ "${#enc}" -ne 32 ]; then
    fail "AP_ENCRYPTION_KEY must be exactly 32 hex characters (openssl rand -hex 16); got ${#enc}."
  fi
  check_secret "AP_JWT_SECRET" "$(lookup AP_JWT_SECRET activepieces/.env)" '' 32

  local pg
  pg=$(lookup AP_POSTGRES_URL activepieces/.env)
  if [ -z "$pg" ]; then
    fail "AP_POSTGRES_URL is unset — point it at your Neon database."
  elif [ "${pg#*-pooler}" = "$pg" ] && [ "${pg#*neon.tech}" != "$pg" ]; then
    # Neon's non-pooled endpoint caps concurrent connections far lower than a
    # long-running worker pool wants; the pooled one is free and same-region.
    warn "AP_POSTGRES_URL points at a Neon endpoint without '-pooler'."
    echo "         Use the pooled endpoint (PgBouncer, free) for a long-running service."
  else
    pass "AP_POSTGRES_URL is set."
  fi

  local redis_host
  redis_host=$(lookup AP_REDIS_HOST activepieces/.env)
  if [ -z "$redis_host" ]; then
    fail "AP_REDIS_HOST is unset — point it at the local ap-redis service."
  elif [ "$redis_host" = "ap-redis" ]; then
    pass "AP_REDIS_HOST points at the local ap-redis service."
  else
    # Learned the expensive way on 2026-08-29. Upstash's free tier caps total
    # REQUESTS at 500,000 a month — about 11.5 commands a minute — and a BullMQ
    # worker polls its queue continuously whether or not a flow is running. The
    # cap was hit, every flow stopped for 14 hours, and the container reported
    # `healthy` throughout while logging 454,605 identical errors.
    #
    # This is a warning rather than a failure because a PAID hosted Redis is a
    # perfectly good choice. It is the free tiers that cannot hold a job queue.
    warn "AP_REDIS_HOST=$redis_host is not the local ap-redis service."
    echo "         A request-capped free tier cannot hold a BullMQ queue: the worker polls"
    echo "         continuously, and 500k requests/month is ~11.5 per minute. When it runs"
    echo "         out, flows stop silently and the container still reports healthy."
    echo "         Offload what is billed by SIZE (Neon/Postgres), not by CALL (Redis)."
  fi

  # Upstream issue #4857: AP_REDIS_USE_SSL=false still negotiates TLS. Only
  # absence disables it, so a literal "false" here is a misconfiguration that
  # fails at connect time with a confusing error.
  local redis_ssl
  redis_ssl=$(lookup AP_REDIS_USE_SSL activepieces/.env)
  if [ "$redis_ssl" = "false" ]; then
    fail "AP_REDIS_USE_SSL=false still forces TLS upstream. Remove the line entirely to disable it."
  fi

  local frontend
  frontend=$(lookup AP_FRONTEND_URL activepieces/.env)
  case "$frontend" in
    *localhost*|*127.0.0.1*)
      warn "AP_FRONTEND_URL is $frontend — inbound webhooks from Slack/GitHub will not reach this instance."
      echo "         Fine while you are tunnelling in over SSH; set the public URL once it is proxied."
      ;;
    "")
      fail "AP_FRONTEND_URL is unset."
      ;;
    *)
      pass "AP_FRONTEND_URL is set to $frontend."
      ;;
  esac

  check_bind_host "AP_BIND_HOST" "$(lookup AP_BIND_HOST)" \
    "Activepieces authenticates, but its webhook endpoints are public by design."
}

check_proxy() {
  echo "profile: proxy (Caddy + Let's Encrypt)"
  local domain
  domain=$(lookup OMNIROUTE_PUBLIC_DOMAIN .env)

  if [ -z "$domain" ]; then
    fail "OMNIROUTE_PUBLIC_DOMAIN is unset — Caddy would try to serve the compose placeholder."
  elif [ "$domain" = "$PLACEHOLDER_PUBLIC_DOMAIN" ]; then
    fail "OMNIROUTE_PUBLIC_DOMAIN is still $PLACEHOLDER_PUBLIC_DOMAIN."
  elif [ "${domain#*.}" = "$domain" ]; then
    # Let's Encrypt will not issue for a bare hostname, and Caddy would retry
    # the failing ACME order on every boot rather than surfacing it once.
    fail "OMNIROUTE_PUBLIC_DOMAIN=$domain is not a fully-qualified domain name."
  else
    pass "OMNIROUTE_PUBLIC_DOMAIN is set to $domain."
  fi

  # Optional second site. Unset is a valid, safe state: the Caddyfile falls
  # back to a .localhost name that Caddy serves from its internal CA, so the
  # config still loads and the site is simply unreachable from outside.
  local ap_domain
  ap_domain=$(lookup ACTIVEPIECES_PUBLIC_DOMAIN .env)
  if [ -z "$ap_domain" ]; then
    pass "ACTIVEPIECES_PUBLIC_DOMAIN is unset — Activepieces stays private (SSH tunnel only)."
  elif [ "${ap_domain#*.}" = "$ap_domain" ]; then
    fail "ACTIVEPIECES_PUBLIC_DOMAIN=$ap_domain is not a fully-qualified domain name."
  elif [ "$ap_domain" = "$domain" ]; then
    # Both sites would claim the same name; Caddy loads whichever it parses
    # last and the other silently stops answering.
    fail "ACTIVEPIECES_PUBLIC_DOMAIN and OMNIROUTE_PUBLIC_DOMAIN are both $ap_domain."
  else
    pass "ACTIVEPIECES_PUBLIC_DOMAIN is set to $ap_domain."
    # Publishing the dashboard is only defensible because Activepieces closes
    # registration itself once the first account exists. That is a property of
    # the running instance, not of this config, so it cannot be checked here.
    warn "Activepieces will be reachable from the internet at $ap_domain."
    echo "         Confirm registration is closed before trusting this:"
    echo "           curl -sf -o /dev/null -w '%{http_code}' -X POST \\"
    echo "             https://$ap_domain/api/v1/authentication/sign-up \\"
    echo "             -H 'Content-Type: application/json' \\"
    echo "             -d '{\"firstName\":\"x\",\"lastName\":\"x\",\"email\":\"probe@example.invalid\",\"password\":\"Pr0be-Test-99xz\",\"trackEvents\":false,\"newsLetter\":false}'"
    echo "         403 (INVITATION_ONLY_SIGN_UP) is what you want. 200 means anyone"
    echo "         who finds the URL can register and run code on this host."
  fi

  # OmniRoute's own two "safe on localhost, unsafe in public" defaults. Both
  # are documented as such in omniroute/.env.example, and both ship as the
  # unsafe value — which is correct for a local-first tool and wrong the
  # moment Caddy puts it on the internet. Blocking, not a warning: publishing
  # with REQUIRE_API_KEY=false hands every passer-by a free LLM gateway
  # spending your provider credit. Found live on 2026-08-28 — an invalid key
  # and no key at all both returned 200 with a real completion.
  local require_key cookie_secure
  require_key=$(lookup REQUIRE_API_KEY omniroute/.env)
  cookie_secure=$(lookup AUTH_COOKIE_SECURE omniroute/.env)

  if [ "$require_key" = "true" ]; then
    pass "REQUIRE_API_KEY=true — /v1/* rejects unauthenticated callers."
  else
    fail "REQUIRE_API_KEY is '${require_key:-unset}'. Publishing with this off means anyone who finds the domain can spend your provider credit."
    echo "         Set REQUIRE_API_KEY=true in omniroute/.env, then verify:"
    echo "           curl -s -o /dev/null -w '%{http_code}' -X POST https://YOUR_DOMAIN/v1/chat/completions \\"
    echo "             -H 'Content-Type: application/json' -d '{\"model\":\"oc/big-pickle\",\"messages\":[]}'"
    echo "         401 is what you want. 200 means the gateway is open to the world."
  fi

  if [ "$cookie_secure" = "true" ]; then
    pass "AUTH_COOKIE_SECURE=true — session cookies carry the Secure flag."
  else
    fail "AUTH_COOKIE_SECURE is '${cookie_secure:-unset}'. omniroute/.env.example says it MUST be true in any non-localhost deployment."
  fi

  if [ ! -f caddy/Caddyfile ]; then
    fail "caddy/Caddyfile is missing — the compose file bind-mounts it read-only and Caddy will not start."
  else
    pass "caddy/Caddyfile is present."
  fi

  # Caddy publishes 80/443 on all interfaces by design: it is the TLS
  # terminator, and ACME HTTP-01 requires port 80 to be reachable from the
  # public internet. Flagged as informational, not a warning, so it does not
  # read as the accidental-exposure case check_bind_host exists to catch.
  echo "         Note: this profile publishes 80/443 on every interface — that is"
  echo "         intended. Keep DASHBOARD_PORT closed at the cloud firewall so the"
  echo "         proxy stays the only way in."
}

check_tracing() {
  echo "profile: tracing (OTel Collector -> Langfuse)"

  local endpoint auth otel_target
  endpoint=$(lookup LANGFUSE_OTLP_ENDPOINT .env)
  auth=$(lookup LANGFUSE_OTLP_AUTH .env)
  # omniroute/.env, not the root .env: the gateway reads its own env_file, and
  # the root compose file is forbidden from redeclaring omniroute-base to pass
  # variables in (doing so is what turned every Docker CI job red).
  otel_target=$(lookup OMNIROUTE_OTEL_ENDPOINT omniroute/.env)

  if [ -z "$endpoint" ]; then
    pass "LANGFUSE_OTLP_ENDPOINT unset — the compose default (Langfuse Cloud EU) applies."
  elif [ "${endpoint%/api/public/otel}" = "$endpoint" ]; then
    # The exporter appends /v1/traces itself, so the base URL must stop at
    # /api/public/otel. A URL that already includes the signal path produces
    # .../v1/traces/v1/traces and a 404 that looks like an auth problem.
    warn "LANGFUSE_OTLP_ENDPOINT=$endpoint does not end in /api/public/otel."
    echo "         The exporter appends /v1/traces itself; include it here and you get a doubled path."
  else
    pass "LANGFUSE_OTLP_ENDPOINT is set to $endpoint."
  fi

  case "$auth" in
    "" ) fail "LANGFUSE_OTLP_AUTH is unset. Traces would be rejected by Langfuse with 401." ;;
    CHANGEME-basic-base64 ) fail "LANGFUSE_OTLP_AUTH is still the compose placeholder." ;;
    Basic\ * ) pass "LANGFUSE_OTLP_AUTH carries a Basic credential." ;;
    * ) fail "LANGFUSE_OTLP_AUTH must start with 'Basic ' — the collector passes it through verbatim." ;;
  esac
  if [ -n "$auth" ] && [ "$auth" != "CHANGEME-basic-base64" ]; then
    echo "         Build it as:  printf 'Basic %s' \"$(printf '%s' 'pk-lf-...:sk-lf-...' | base64 -w0)\""
  fi

  # The collector can be perfectly configured and still receive nothing.
  if [ -z "$otel_target" ]; then
    fail "OMNIROUTE_OTEL_ENDPOINT is unset, so OmniRoute's exporter stays off and the collector will sit idle."
    echo "         Set OMNIROUTE_OTEL_ENDPOINT=http://otel-collector:4318 in omniroute/.env."
  elif [ "${otel_target#http://otel-collector}" = "$otel_target" ]; then
    warn "OMNIROUTE_OTEL_ENDPOINT=$otel_target does not point at the collector service."
  else
    pass "OMNIROUTE_OTEL_ENDPOINT points at the collector."
  fi

  if [ ! -f otel-collector/config.yaml ]; then
    fail "otel-collector/config.yaml is missing — the compose file mounts it read-only and the collector will not start."
  else
    pass "otel-collector/config.yaml is present."
  fi
}

check_codegraph() {
  echo "profile: codegraph (graphify MCP server)"

  local key free_gb
  key=$(lookup GRAPHIFY_API_KEY .env)

  # Blocking, not a warning. graphify takes the key from GRAPHIFY_API_KEY, and
  # an empty value is not "reject everything" — the HTTP transport simply has
  # no key to require, which publishes a queryable index of the whole codebase
  # to anything that reaches the port.
  case "$key" in
    "" ) fail "GRAPHIFY_API_KEY is unset. The MCP server would serve the code graph with no authentication." ;;
    CHANGEME* ) fail "GRAPHIFY_API_KEY is still a placeholder." ;;
    * )
      if [ "${#key}" -lt 24 ]; then
        fail "GRAPHIFY_API_KEY is ${#key} characters. Use at least 24 — it is the only thing in front of the graph."
      else
        pass "GRAPHIFY_API_KEY is set (${#key} characters)."
      fi
      ;;
  esac

  check_bind_host "CODEGRAPH_BIND_HOST" "$(lookup CODEGRAPH_BIND_HOST .env)" \
    "Reach it over an SSH tunnel instead (ssh -L 8130:127.0.0.1:8130 vps); the API key is the only control in front of it."

  if [ ! -f codegraph/Dockerfile ]; then
    fail "codegraph/Dockerfile is missing — both codegraph services build from it."
  else
    pass "codegraph/Dockerfile is present."
  fi

  check_disk_gb 8 "the 496 MB image, an 82 MB graph, and room for a 4 GB build container"
}

# Disk is one of the very few runtime-shaped facts knowable before `up`, and
# these profiles are the first things in this repo to pull multiple GB.
check_disk_gb() {
  local needed="$1" why="$2" free_gb raw
  # Both of the early returns here used to be bare `return 0`: no output, no
  # warning, exit 0. An operator reading a clean preflight had no way to tell
  # "disk was checked and is fine" from "disk was never checked" — in front of
  # an 8.45 GB image on a host measured dropping to 9.2 GB free. Not being able
  # to measure is now a failure, because vouching for a number nobody read is
  # the thing this script exists to prevent.
  if ! command -v "${DF_CMD:-df}" >/dev/null 2>&1; then
    fail "'${DF_CMD:-df}' not found, so free disk cannot be measured — refusing to vouch for ${needed}G for $why."
    return
  fi
  # --output is GNU coreutils only. Fall back to POSIX `df -k`, whose available
  # column is 4, before giving up: without this the fix would turn today's
  # silent pass into a hard block on Alpine or macOS.
  raw=$("${DF_CMD:-df}" -BG --output=avail . 2>/dev/null | tail -1) || raw=""
  free_gb=$(printf '%s' "$raw" | tr -dc '0-9')
  if [ -z "$free_gb" ]; then
    raw=$("${DF_CMD:-df}" -k . 2>/dev/null | tail -1) || raw=""
    free_gb=$(printf '%s' "$raw" | awk '{print int($4 / 1048576)}' 2>/dev/null | tr -dc '0-9')
  fi
  if [ -z "$free_gb" ]; then
    fail "Could not parse free disk from df — refusing to vouch for ${needed}G for $why."
    echo "         Raw output was: ${raw:-<empty>}"
    return
  fi
  if [ "$free_gb" -lt "$needed" ]; then
    fail "Only ${free_gb}G free on this filesystem; ${needed}G wanted for $why."
    echo "         'docker builder prune -f' is usually the cheapest win — it freed 9.4G here."
  else
    pass "${free_gb}G free on this filesystem (${needed}G wanted)."
    report_reclaimable_cache
  fi
}

# Mentioned on a PASS, not only on a failure.
#
# The failure path already suggests `docker builder prune`, which is the right
# advice at the wrong time: by then the deploy is blocked. Repeated image
# builds put 14.1G of build cache on this host in a single day — 3.3G of it
# older than 24 hours — while the disk check kept passing and saying nothing.
# Naming it while there is still room is what turns a number into an action.
#
# Best-effort throughout: no docker, a docker that errors, or output this
# cannot parse must all leave the disk check exactly as it was.
report_reclaimable_cache() {
  local raw gb
  command -v "${DOCKER_CMD:-docker}" >/dev/null 2>&1 || return 0
  raw=$("${DOCKER_CMD:-docker}" system df --format '{{.Type}} {{.Reclaimable}}' 2>/dev/null         | awk '/Build Cache/ {print $3}') || return 0
  case "$raw" in
    *GB) gb=$(printf '%s' "$raw" | tr -dc '0-9.' | cut -d. -f1) ;;
    *)   return 0 ;;   # bytes, kB or MB — not worth a line
  esac
  [ -n "$gb" ] || return 0
  if [ "$gb" -ge 5 ]; then
    warn "${gb}G of Docker build cache is reclaimable. 'docker builder prune -f --filter until=24h' keeps today's layers and frees the rest."
  fi
}

check_localmodel() {
  echo "profile: localmodel (Ollama behind OmniRoute)"

  local model keep_alive guard
  model=$(lookup OLLAMA_MODEL .env)
  keep_alive=$(lookup OLLAMA_KEEP_ALIVE .env)
  guard=$(lookup OMNIROUTE_ALLOW_LOCAL_PROVIDER_URLS omniroute/.env)

  if [ -z "$model" ]; then
    pass "OLLAMA_MODEL unset — the compose default (qwen2.5:3b-instruct-q4_K_M) applies."
  else
    pass "OLLAMA_MODEL is $model."
  fi

  # The ollama image carries CUDA and ROCm runtimes even with no GPU present:
  # 8.45 GB measured, roughly double what a slim CPU image would cost. Plus
  # ~2 GB for a 3B model.
  check_disk_gb 12 "the 8.45 GB ollama image and a ~2 GB model"

  # Not a hard failure, because it is a legitimate choice — but on this host it
  # collides with codegraph-build, which needs 4 GB and cannot get it while a
  # 2.1 GB model sits resident.
  if [ "$keep_alive" = "-1" ]; then
    warn "OLLAMA_KEEP_ALIVE=-1 holds ~2.1 GB permanently."
    echo "         scripts/codegraph-refresh.sh unloads it before building, but budget for it."
  fi

  # outboundUrlGuardPolicy.ts defaults local provider URLs to allowed. Turning
  # that off turns a working setup into a guard error that reads like the model
  # server being down — a wrong diagnosis, which is worse than a clear failure.
  case "$guard" in
    ""|true|1 ) : ;;
    * ) fail "OMNIROUTE_ALLOW_LOCAL_PROVIDER_URLS=$guard blocks the gateway from reaching http://ollama:11434." ;;
  esac

  echo "         After 'up', register the provider and PROVE it:"
  echo "           ./scripts/localmodel-register.sh"
  echo "         A dashboard connection saved without an explicit Base URL keeps"
  echo "         localDefault http://localhost:11434/v1, which from inside the"
  echo "         gateway container is the gateway itself."
}

check_observability() {
  echo "profile: observability (Langfuse)"
  check_secret "NEXTAUTH_SECRET" \
    "$(lookup NEXTAUTH_SECRET observability/.env)" "$PLACEHOLDER_NEXTAUTH" 32
  check_secret "MINIO_ROOT_PASSWORD" \
    "$(lookup MINIO_ROOT_PASSWORD observability/.env)" "$PLACEHOLDER_MINIO_PASSWORD" 16
  check_secret "SALT" "$(lookup SALT observability/.env)" '' 32
  check_secret "ENCRYPTION_KEY" "$(lookup ENCRYPTION_KEY observability/.env)" '' 64
  check_bind_host "LANGFUSE_WEB_BIND_HOST" "$(lookup LANGFUSE_WEB_BIND_HOST observability/.env)" \
    "Langfuse authenticates, but also offers self-service signup."
  check_bind_host "LANGFUSE_MINIO_BIND_HOST" "$(lookup LANGFUSE_MINIO_BIND_HOST observability/.env)" \
    "That is the object store's S3 API, guarded only by MINIO_ROOT_PASSWORD."
}

# Exercises the pure logic above with known inputs, so CI can prove this
# script actually catches what it claims to without needing a Docker daemon
# or any real secrets.
self_test() {
  local failed=0
  assert_eq() {
    if [ "$2" = "$3" ]; then
      green "  ok    $1"
    else
      red "  FAIL  $1 (expected '$3', got '$2')"
      failed=1
    fi
  }

  echo "self-test: check_secret"
  errors=0; check_secret "T" "" "PLACEHOLDER" >/dev/null;             assert_eq "empty value fails" "$errors" 1
  errors=0; check_secret "T" "PLACEHOLDER" "PLACEHOLDER" >/dev/null;  assert_eq "placeholder fails" "$errors" 1
  errors=0; check_secret "T" "short" "PLACEHOLDER" >/dev/null;        assert_eq "too-short fails" "$errors" 1
  errors=0; check_secret "T" "$(printf 'x%.0s' {1..40})" "PLACEHOLDER" >/dev/null
  assert_eq "good value passes" "$errors" 0

  echo "self-test: check_bind_host"
  warnings=0; check_bind_host "B" "127.0.0.1" "" >/dev/null; assert_eq "loopback passes" "$warnings" 0
  warnings=0; check_bind_host "B" "" "" >/dev/null;          assert_eq "unset defaults to loopback" "$warnings" 0
  warnings=0; check_bind_host "B" "0.0.0.0" "" >/dev/null;   assert_eq "0.0.0.0 warns" "$warnings" 1

  # Until 2026-08-30 this harness covered only the functions that JUDGE a value
  # against known inputs, and none that GO AND READ something. Both instruments
  # that broke that day — a probe whose exit code was eaten by a pipe, and this
  # very check returning a silent pass — would have gone on passing every test
  # in the repo. So the acquiring half is stubbed and asserted too: what matters
  # is that "could not measure" never collapses into "measured fine".
  echo "self-test: check_disk_gb"
  local stub; stub=$(mktemp -d)
  printf '#!/bin/sh\nexit 1\n'                                 > "$stub/df-fails";   chmod +x "$stub/df-fails"
  printf '#!/bin/sh\nexit 0\n'                                 > "$stub/df-empty";   chmod +x "$stub/df-empty"
  printf '#!/bin/sh\necho "Avail\\nnot-a-number"\n'            > "$stub/df-garbage"; chmod +x "$stub/df-garbage"
  printf '#!/bin/sh\necho Avail\necho 99G\n'                   > "$stub/df-roomy";   chmod +x "$stub/df-roomy"
  printf '#!/bin/sh\necho Avail\necho 2G\n'                    > "$stub/df-tight";   chmod +x "$stub/df-tight"

  errors=0; DF_CMD="$stub/nonexistent" check_disk_gb 8 "t" >/dev/null 2>&1 || true
  assert_eq "missing df fails, does not silently pass" "$errors" 1
  errors=0; DF_CMD="$stub/df-fails"   check_disk_gb 8 "t" >/dev/null 2>&1; assert_eq "df exiting non-zero fails" "$errors" 1
  errors=0; DF_CMD="$stub/df-empty"   check_disk_gb 8 "t" >/dev/null 2>&1; assert_eq "df returning nothing fails" "$errors" 1
  errors=0; DF_CMD="$stub/df-garbage" check_disk_gb 8 "t" >/dev/null 2>&1; assert_eq "unparseable df output fails" "$errors" 1
  errors=0; DF_CMD="$stub/df-tight"   check_disk_gb 8 "t" >/dev/null 2>&1; assert_eq "too little disk fails" "$errors" 1
  errors=0; DF_CMD="$stub/df-roomy"   check_disk_gb 8 "t" >/dev/null 2>&1; assert_eq "enough disk passes" "$errors" 0
  rm -rf "$stub"

  echo "self-test: report_reclaimable_cache"
  local stub; stub=$(mktemp -d)
  # Shaped exactly like the real `docker system df --format` output, which was
  # checked rather than assumed: "Build Cache 10.14GB", no count column and no
  # percentage suffix on that row. A stub that guesses the format tests the
  # stub.
  printf '#!/bin/sh
echo "Images 496.1MB (3%%)"
echo "Build Cache 10.14GB"
' > "$stub/docker-big"
  printf '#!/bin/sh
echo "Build Cache 900MB"
'                                 > "$stub/docker-small"
  printf '#!/bin/sh
exit 1
'                          > "$stub/docker-broken"
  chmod +x "$stub"/docker-*
  warnings=0; DOCKER_CMD="$stub/docker-big"    report_reclaimable_cache >/dev/null
  assert_eq "10G reclaimable warns" "$warnings" 1
  warnings=0; DOCKER_CMD="$stub/docker-small"  report_reclaimable_cache >/dev/null
  assert_eq "900MB is not worth a line" "$warnings" 0
  warnings=0; DOCKER_CMD="$stub/docker-broken" report_reclaimable_cache >/dev/null 2>&1
  assert_eq "a broken docker stays silent" "$warnings" 0
  warnings=0; DOCKER_CMD="$stub/nope"          report_reclaimable_cache >/dev/null 2>&1
  assert_eq "no docker at all stays silent" "$warnings" 0
  rm -rf "$stub"

  echo "self-test: check_agent_tools_wiring"
  warnings=0; check_agent_tools_wiring "" "" >/dev/null
  assert_eq "no key + default allowlist warns (silently toolless)" "$warnings" 1
  warnings=0; check_agent_tools_wiring "" "none" >/dev/null
  assert_eq "no key + none is a deliberate choice, no warning" "$warnings" 0
  warnings=0; check_agent_tools_wiring "k" "omniroute_web_search" >/dev/null
  assert_eq "key + allowlist warns only about manage scope" "$warnings" 1
  warnings=0; check_agent_tools_wiring "k" "NONE" >/dev/null
  assert_eq "key + none warns twice, and is case-insensitive" "$warnings" 2

  echo "self-test: lookup"
  local tmp; tmp=$(mktemp)
  printf 'FOO=first\nFOO=second\nBAR=value # trailing\n' > "$tmp"
  assert_eq "last assignment wins" "$(lookup FOO "$tmp")" "second"
  assert_eq "inline comment kept (matches Compose)" "$(lookup BAR "$tmp")" "value # trailing"
  assert_eq "environment beats .env file" "$(FOO=from-env lookup FOO "$tmp")" "from-env"
  rm -f "$tmp"

  if [ "$failed" -eq 0 ]; then
    green "self-test passed"
    return 0
  fi
  red "self-test FAILED"
  return 1
}

main() {
  if [ "${1:-}" = "--self-test" ]; then
    self_test
    exit $?
  fi

  if [ "$#" -eq 0 ]; then
    echo "usage: $0 <profile> [profile...]   (base | agent-sidecar | agent-sidecar-http | openhands |
                                            observability | proxy | workflow |
                                            tracing)" >&2
    echo "       $0 --self-test" >&2
    exit 2
  fi

  # Run from the repo root so the relative paths above resolve regardless of
  # where the operator invoked this from.
  cd "$(dirname "$0")/.."

  echo "STAX preflight — profiles: $*"
  echo
  for profile in "$@"; do
    case "$profile" in
      base)          check_base ;;
      agent-sidecar) check_agent_sidecar ;;
      agent-sidecar-http) check_agent_sidecar_http ;;
      openhands)     check_openhands ;;
      observability) check_observability ;;
      tracing)       check_tracing ;;
      proxy)         check_proxy ;;
      workflow)      check_workflow ;;
      codegraph)     check_codegraph ;;
      localmodel)    check_localmodel ;;
      *) fail "unknown profile '$profile'" ;;
    esac
    echo
  done

  if [ "$errors" -gt 0 ]; then
    red "$errors blocking problem(s), $warnings warning(s). Not safe to deploy as-is."
    exit 1
  fi
  if [ "$warnings" -gt 0 ]; then
    yellow "$warnings warning(s), no blocking problems. Review them, then deploy."
    exit 0
  fi
  green "All checks passed."
}

main "$@"
