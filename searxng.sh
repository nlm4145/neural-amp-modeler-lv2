#!/usr/bin/env bash
#
# SearXNG Management Script for neural-amp-modeler-lv2
#
# Allows starting, stopping, installing, and testing a local SearXNG search engine
# instance. Automatically launches Docker Desktop if it is not currently running.
#

set -euo pipefail

# ANSI Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# Resolve root and directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEARXNG_DIR="${SEARXNG_DIR:-"${SCRIPT_DIR}/tools/searxng"}"
CONFIG_DIR="${SEARXNG_DIR}/core-config"
ENV_FILE="${SEARXNG_DIR}/.env"

# Helper to verify if SearXNG is genuinely up and running on the target port
is_searxng_running() {
    local target_port="${1:-"${PORT}"}"
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        if docker ps --filter "name=searxng-core" --filter "status=running" -q 2>/dev/null | grep -q .; then
            if curl -sI "http://localhost:${target_port}" 2>/dev/null | grep -qi "granian\|searxng"; then
                return 0
            fi
        fi
    fi
    return 1
}
update_env_port() {
    local new_port="$1"
    if [[ -f "${ENV_FILE}" ]]; then
        if grep -q "^SEARXNG_PORT=" "${ENV_FILE}"; then
            if [[ "$(uname -s)" == "Darwin" ]]; then
                sed -i '' "s/^SEARXNG_PORT=.*/SEARXNG_PORT=${new_port}/" "${ENV_FILE}"
            else
                sed -i "s/^SEARXNG_PORT=.*/SEARXNG_PORT=${new_port}/" "${ENV_FILE}"
            fi
        else
            echo "SEARXNG_PORT=${new_port}" >> "${ENV_FILE}"
        fi
    fi
}

# Resolve port:
# 1. Environment variable if explicitly passed
# 2. Last used port saved in .env (remembers previous port across runs)
# 3. Default to 8080
if [[ -n "${SEARXNG_PORT:-}" ]]; then
    PORT="${SEARXNG_PORT}"
    update_env_port "${PORT}"
elif [[ -f "${ENV_FILE}" ]] && grep -q "^SEARXNG_PORT=" "${ENV_FILE}"; then
    PORT="$(grep "^SEARXNG_PORT=" "${ENV_FILE}" | cut -d'=' -f2 | tr -d ' ')"
else
    PORT="8080"
fi

BASE_URL="http://localhost:${PORT}"

# Wrapper to support both 'docker compose' (v2 plugin) and legacy 'docker-compose'
compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose "$@"
    else
        echo -e "${RED}[ERROR] Neither 'docker compose' nor 'docker-compose' found in PATH.${NC}" >&2
        exit 1
    fi
}

# Reclaim target port if occupied by stale Docker containers or orphaned processes
reclaim_port() {
    local target_port="${1:-"${PORT}"}"

    if ! command -v lsof >/dev/null 2>&1; then
        return 0
    fi

    local pids
    pids="$(lsof -ti :${target_port} 2>/dev/null || true)"
    if [[ -z "${pids}" ]]; then
        return 0
    fi

    # 1. If Docker is running, check if any container is publishing this port
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        local cids
        cids="$(docker ps -a -q --filter "publish=${target_port}")"
        if [[ -n "${cids}" ]]; then
            for cid in ${cids}; do
                local cname
                cname="$(docker inspect --format '{{.Name}}' "${cid}" 2>/dev/null | sed 's/^\///' || true)"
                # If it is our active and responsive searxng-core, we can keep it
                if [[ "${cname}" == "searxng-core" ]] && curl -sI "http://localhost:${target_port}" 2>/dev/null | grep -q "200 OK"; then
                    return 0
                fi
                echo -e "${YELLOW}[!] Port ${target_port} is held by container '${cname:-${cid}}'. Reclaiming port...${NC}"
                docker rm -f "${cid}" >/dev/null 2>&1 || true
            done
            sleep 1
        fi
    fi

    # 2. Check if an orphaned process is still holding the port
    pids="$(lsof -ti :${target_port} 2>/dev/null || true)"
    if [[ -n "${pids}" ]]; then
        for pid in ${pids}; do
            local pname
            pname="$(ps -p "${pid}" -o comm= 2>/dev/null || echo "unknown")"
            if [[ "${pname}" =~ (granian|searx|docker-proxy) ]]; then
                echo -e "${YELLOW}[!] Port ${target_port} is held by orphaned process '${pname}' (PID: ${pid}). Reclaiming port...${NC}"
                kill -9 "${pid}" 2>/dev/null || true
            elif [[ "${pname}" =~ com\.docker ]]; then
                # Docker daemon / backend holding the port, but no active container was listed
                echo -e "${BLUE}[*] Waiting for Docker proxy to release port ${target_port}...${NC}"
                sleep 2
            else
                echo -e "${RED}[ERROR] Port ${target_port} is occupied by non-SearXNG process: '${pname}' (PID: ${pid}).${NC}" >&2
                echo -e "Please stop '${pname}' or specify a different port: ${BOLD}SEARXNG_PORT=<port> $0 start${NC}" >&2
                exit 1
            fi
        done
        sleep 1
    fi

    pids="$(lsof -ti :${target_port} 2>/dev/null || true)"
    if [[ -z "${pids}" ]]; then
        echo -e "${GREEN}✓ Successfully reclaimed port ${target_port}.${NC}"
    fi
}
ensure_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] 'docker' CLI not found.${NC}" >&2
        echo "Please install Docker Desktop: https://www.docker.com/products/docker-desktop/" >&2
        exit 1
    fi

    if docker info >/dev/null 2>&1; then
        return 0
    fi

    echo -e "${YELLOW}[!] Docker daemon is not running.${NC}"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        echo -e "${BLUE}[*] Launching Docker Desktop...${NC}"
        open -a Docker 2>/dev/null || open -a /Applications/Docker.app 2>/dev/null || true

        echo -n "Waiting for Docker daemon to become ready"
        local retries=40
        while (( retries > 0 )); do
            if docker info >/dev/null 2>&1; then
                echo -e " ${GREEN}✓ Docker is ready!${NC}"
                return 0
            fi
            echo -n "."
            sleep 2
            ((retries--))
        done
        echo ""
        echo -e "${RED}[ERROR] Docker daemon timed out. Please check Docker Desktop manually.${NC}" >&2
        exit 1
    else
        echo -e "${RED}[ERROR] Docker daemon is not active. Please start the Docker service.${NC}" >&2
        exit 1
    fi
}

# Install / scaffold configuration files and pull images
install_searxng() {
    echo -e "${BLUE}[*] Setting up SearXNG in: ${SEARXNG_DIR}${NC}"
    mkdir -p "${CONFIG_DIR}"

    # 1. docker-compose.yml
    if [[ ! -f "${SEARXNG_DIR}/docker-compose.yml" ]]; then
        echo -e "  → Generating docker-compose.yml..."
        cat <<'EOF' > "${SEARXNG_DIR}/docker-compose.yml"
name: searxng

services:
  core:
    container_name: searxng-core
    image: docker.io/searxng/searxng:${SEARXNG_VERSION:-latest}
    restart: unless-stopped
    ports:
      - "${SEARXNG_PORT:-8080}:${SEARXNG_PORT:-8080}"
    env_file: ./.env
    volumes:
      - ./core-config/:/etc/searxng/:Z
      - core-data:/var/cache/searxng/

  valkey:
    container_name: searxng-valkey
    image: docker.io/valkey/valkey:9-alpine
    command: valkey-server --save 300 1 --save 60 1000 --loglevel warning
    restart: unless-stopped
    volumes:
      - valkey-data:/data/

volumes:
  core-data:
  valkey-data:
EOF
    fi

    # 2. .env file with generated secret key
    if [[ ! -f "${SEARXNG_DIR}/.env" ]]; then
        echo -e "  → Generating secret key & .env..."
        local secret_key
        if command -v openssl >/dev/null 2>&1; then
            secret_key="$(openssl rand -hex 32)"
        else
            secret_key="$(head -c 32 /dev/urandom | xxd -p | tr -d '\n')"
        fi
        cat <<EOF > "${SEARXNG_DIR}/.env"
SEARXNG_VERSION=latest
SEARXNG_PORT=${PORT}
SEARXNG_SECRET=${secret_key}
SEARXNG_VALKEY_URL=valkey://valkey:6379/0
EOF
    fi

    # 3. settings.yml (enables HTML and JSON search formats, image proxy, and valkey)
    if [[ ! -f "${CONFIG_DIR}/settings.yml" ]]; then
        echo -e "  → Generating core-config/settings.yml..."
        local secret_key
        secret_key="$(grep "SEARXNG_SECRET=" "${SEARXNG_DIR}/.env" | cut -d'=' -f2)"
        cat <<EOF > "${CONFIG_DIR}/settings.yml"
use_default_settings: true

general:
  debug: false
  instance_name: "SearXNG Local"

search:
  safe_search: 0
  autocomplete: "duckduckgo"
  formats:
    - html
    - json

server:
  secret_key: "${secret_key}"
  limiter: false
  image_proxy: true

valkey:
  url: valkey://valkey:6379/0
EOF
    fi

    # 4. limiter.toml
    if [[ ! -f "${CONFIG_DIR}/limiter.toml" ]]; then
        echo -e "  → Downloading default limiter.toml..."
        curl -fsSL https://raw.githubusercontent.com/searxng/searxng/master/searx/limiter.toml -o "${CONFIG_DIR}/limiter.toml" 2>/dev/null || touch "${CONFIG_DIR}/limiter.toml"
    fi

    # 5. Pull Docker images
    ensure_docker
    echo -e "  → Pulling Docker images..."
    (cd "${SEARXNG_DIR}" && compose pull)

    echo -e "${GREEN}✓ SearXNG installation & configuration ready.${NC}"
}

# Start the SearXNG services
start_searxng() {
    ensure_docker

    # Fast path: already genuinely running and responsive on target port
    if is_searxng_running "${PORT}"; then
        echo -e "${GREEN}✓ SearXNG is already running on port ${PORT}: ${BOLD}${BASE_URL}${NC}"
        return 0
    fi

    # Reclaim port if occupied by stale container or lingering process
    reclaim_port "${PORT}"

    if [[ ! -f "${SEARXNG_DIR}/docker-compose.yml" || ! -f "${CONFIG_DIR}/settings.yml" ]]; then
        install_searxng
    fi

    echo -e "${BLUE}[*] Starting SearXNG containers (Port: ${PORT})...${NC}"
    (cd "${SEARXNG_DIR}" && compose up -d)

    echo -n "Waiting for SearXNG service at ${BASE_URL}"
    local retries=25
    while (( retries > 0 )); do
        if curl -sI "${BASE_URL}" 2>/dev/null | grep -q "200 OK"; then
            echo -e " ${GREEN}✓ Online!${NC}"
            echo -e "${BOLD}Web Interface: ${GREEN}${BASE_URL}${NC}"
            return 0
        fi
        echo -n "."
        sleep 1
        ((retries--))
    done
    echo ""
    echo -e "${YELLOW}[!] Service started, but HTTP 200 check timed out. View logs with: $0 logs${NC}"
}

# Stop the SearXNG services
stop_searxng() {
    ensure_docker
    if [[ -d "${SEARXNG_DIR}" ]]; then
        echo -e "${BLUE}[*] Stopping SearXNG containers...${NC}"
        (cd "${SEARXNG_DIR}" && compose down)
        echo -e "${GREEN}✓ SearXNG stopped.${NC}"
    else
        echo -e "${YELLOW}SearXNG directory not found. Nothing to stop.${NC}"
    fi
}

# Restart the SearXNG services
restart_searxng() {
    stop_searxng
    start_searxng
}

# Show status
status_searxng() {
    ensure_docker
    echo -e "${BOLD}SearXNG Containers:${NC}"
    if [[ -d "${SEARXNG_DIR}" ]]; then
        (cd "${SEARXNG_DIR}" && compose ps)
    else
        echo "Not installed yet. Run '$0 install'."
    fi
    echo ""
    if curl -sI "${BASE_URL}" 2>/dev/null | grep -q "200 OK"; then
        echo -e "Web Service Status: ${GREEN}Online${NC} at ${BASE_URL}"
    else
        echo -e "Web Service Status: ${RED}Offline${NC}"
    fi
}

# Run live verification tests
test_searxng() {
    ensure_docker
    if ! curl -sI "${BASE_URL}" 2>/dev/null | grep -q "200 OK"; then
        echo -e "${YELLOW}[!] SearXNG is offline. Launching it now...${NC}"
        start_searxng
    fi

    echo -e "\n${BOLD}============================================================${NC}"
    echo -e "${BOLD}Running SearXNG Verification Suite${NC}"
    echo -e "${BOLD}============================================================${NC}"

    python3 - <<EOF
import urllib.request, urllib.parse, json, sys

base = "${BASE_URL}"

def check_search(label, params):
    url = f"{base}/search?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": "SearXNG-Verification/1.0"})
    with urllib.request.urlopen(req, timeout=10) as r:
        assert r.status == 200
        data = json.loads(r.read().decode())
        results = data.get("results", [])
        engines = sorted(list(set(e for res in results for e in res.get("engines", []))))
        print(f"\n▶ {label}")
        print(f"  Query: \"{params['q']}\"")
        print(f"  Results: {len(results)} found")
        print(f"  Engines: {', '.join(engines[:6])}")
        if results:
            print(f"  Top Match: {results[0].get('title')}")
            print(f"  URL: {results[0].get('url') or results[0].get('img_src')}")

try:
    check_search("General Search", {"q": "neural amp modeler lv2", "format": "json"})
    check_search("IT / Code Search", {"q": "audio plugin dsp c++", "categories": "it", "format": "json"})
    check_search("Image Search", {"q": "guitar vacuum tube amplifier", "categories": "images", "format": "json"})

    # Autocomplete
    ac_url = f"{base}/autocompleter?" + urllib.parse.urlencode({"q": "neural amp"})
    ac_req = urllib.request.Request(ac_url, headers={"User-Agent": "SearXNG-Verification/1.0"})
    with urllib.request.urlopen(ac_req, timeout=5) as r:
        ac_data = json.loads(r.read().decode())
        suggestions = ac_data[1] if len(ac_data) > 1 else []
        print(f"\n▶ Autocomplete: 'neural amp'")
        print(f"  Suggestions: {suggestions[:4]}")

    print("\n" + "=" * 60)
    print("ALL TESTS PASSED SUCCESSFULLY!")
    print("=" * 60)
except Exception as e:
    print(f"\n✗ Test failed: {e}", file=sys.stderr)
    sys.exit(1)
EOF
}

# Perform a terminal search (supports human-readable and raw JSON output)
search_query() {
    local json_output=false

    # Check for --json or -j flag anywhere in arguments
    local clean_args=()
    for arg in "$@"; do
        if [[ "${arg}" == "--json" || "${arg}" == "-j" ]]; then
            json_output=true
        else
            clean_args+=("${arg}")
        fi
    done

    if [[ ${#clean_args[@]} -eq 0 ]]; then
        echo -e "${RED}[ERROR] Please provide a search query.${NC}" >&2
        echo -e "Usage: $0 search [--json] <search terms...>" >&2
        exit 1
    fi

    local query="${clean_args[*]}"
    if ! is_searxng_running "${PORT}"; then
        echo -e "${YELLOW}[!] SearXNG is offline. Launching it now...${NC}" >&2
        start_searxng >&2
    fi

    if [[ "${json_output}" == "true" ]]; then
        python3 - <<EOF
import urllib.request, urllib.parse, json, sys

query = """${query}"""
url = "${BASE_URL}/search?" + urllib.parse.urlencode({"q": query, "format": "json"})
req = urllib.request.Request(url, headers={"User-Agent": "SearXNG-CLI/1.0"})
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        raw = r.read().decode("utf-8")
        # Ensure pretty-printed valid JSON
        parsed = json.loads(raw)
        print(json.dumps(parsed, indent=2))
except Exception as e:
    sys.stderr.write(f"Search query failed: {e}\n")
    sys.exit(1)
EOF
    else
        python3 - <<EOF
import urllib.request, urllib.parse, json, sys

query = """${query}"""
url = "${BASE_URL}/search?" + urllib.parse.urlencode({"q": query, "format": "json"})
req = urllib.request.Request(url, headers={"User-Agent": "SearXNG-CLI/1.0"})
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        data = json.loads(r.read().decode())
        results = data.get("results", [])
        print(f"\nSearXNG results for: \"{query}\" ({len(results)} matches)\n")
        for i, res in enumerate(results[:5], 1):
            title = res.get("title", "No Title")
            link = res.get("url", "")
            engines = ", ".join(res.get("engines", []))
            snippet = res.get("content", "").strip().replace("\n", " ")
            if len(snippet) > 120:
                snippet = snippet[:117] + "..."
            print(f"  \033[1m{i}. {title}\033[0m")
            print(f"     URL:     \033[34m{link}\033[0m")
            print(f"     Engines: {engines}")
            if snippet:
                print(f"     Snippet: {snippet}")
            print()
except Exception as e:
    print(f"Search query failed: {e}", file=sys.stderr)
    sys.exit(1)
EOF
    fi
}

# Open SearXNG in the default browser
open_browser() {
    if ! curl -sI "${BASE_URL}" 2>/dev/null | grep -q "200 OK"; then
        echo -e "${YELLOW}[!] SearXNG is offline. Launching it now...${NC}"
        start_searxng
    fi

    echo -e "${BLUE}[*] Opening ${BASE_URL} in browser...${NC}"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        open "${BASE_URL}"
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "${BASE_URL}"
    else
        echo "Open ${BASE_URL} in your browser."
    fi
}

# Tail logs
tail_logs() {
    ensure_docker
    if [[ -d "${SEARXNG_DIR}" ]]; then
        (cd "${SEARXNG_DIR}" && compose logs -f)
    else
        echo "SearXNG directory not found."
    fi
}

# Print usage
usage() {
    echo -e "${BOLD}SearXNG Management Tool for neural-amp-modeler-lv2${NC}

${BOLD}Usage:${NC}
  $0 [command] [options]

${BOLD}Commands:${NC}
  ${GREEN}start${NC}                  Launch Docker (if closed), install if needed, and start SearXNG
  ${GREEN}stop${NC}                   Stop the SearXNG containers
  ${GREEN}restart${NC}                Restart the SearXNG containers
  ${GREEN}status${NC}                 Check container health, ports, and HTTP availability
  ${GREEN}reclaim [port]${NC}         Free the port from lingering containers or processes
  ${GREEN}install${NC}                Set up configurations, .env, and pull container images
  ${GREEN}test${NC}                   Run automated live search and API test suite
  ${GREEN}search [--json] <q>${NC}    Execute a search (human-readable or raw JSON output)
  ${GREEN}json <q>${NC}               Direct shortcut to search and output raw JSON
  ${GREEN}open${NC}                   Open SearXNG in your default browser
  ${GREEN}logs${NC}                   View and follow live container logs

${BOLD}JSON Mode:${NC}
  SearXNG is pre-configured with JSON API enabled. You can consume it:
  1. Via CLI:         ${BOLD}$0 search --json \"query\"${NC}  or  ${BOLD}$0 json \"query\"${NC}
  2. Via HTTP REST:   ${BOLD}curl \"http://localhost:${PORT}/search?q=query&format=json\"${NC}

${BOLD}Environment Variables:${NC}
  SEARXNG_PORT    Port to listen on (saved and remembered across runs, default: 8080)
  SEARXNG_DIR     Directory for configuration files (default: tools/searxng)

${BOLD}Examples:${NC}
  $0 start
  $0 search \"guitar impulse response\"
  $0 search --json \"nam a2 architecture\" | jq '.results[0].url'
  $0 json \"audio dsp filters\"
  $0 reclaim
  $0 stop"
}

# Command dispatch
case "${1:-}" in
    start|up)
        start_searxng
        ;;
    stop|down)
        stop_searxng
        ;;
    restart)
        restart_searxng
        ;;
    status)
        status_searxng
        ;;
    reclaim)
        shift
        ensure_docker
        reclaim_port "${1:-"${PORT}"}"
        ;;
    install|setup)
        install_searxng
        ;;
    test)
        test_searxng
        ;;
    search)
        shift
        search_query "$@"
        ;;
    json)
        shift
        search_query --json "$@"
        ;;
    open)
        open_browser
        ;;
    logs)
        tail_logs
        ;;
    -h|--help|help)
        usage
        ;;
    "")
        usage
        ;;
    *)
        echo -e "${RED}[ERROR] Unknown command: $1${NC}\n" >&2
        usage
        exit 1
        ;;
esac
