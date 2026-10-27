# SearXNG Local Search Service

A self-contained, containerized SearXNG metasearch instance for `neural-amp-modeler-lv2` with built-in Valkey caching, automated Docker lifecycle management, port persistence/reclamation, and JSON API support.

---

## Quick Reference Commands

All management is handled via the root script `./searxng.sh` (or `scripts/searxng.sh`):

| Command | Description | Example |
| :--- | :--- | :--- |
| **`start`** | Boots Docker Desktop (if closed), pulls images, and starts containers. | `./searxng.sh start` |
| **`stop`** | Stops the SearXNG and Valkey containers. | `./searxng.sh stop` |
| **`restart`** | Restarts the containers cleanly. | `./searxng.sh restart` |
| **`status`** | Displays container state, port bindings, and HTTP health. | `./searxng.sh status` |
| **`reclaim [port]`** | Forcibly frees the port from lingering containers/processes. | `./searxng.sh reclaim` |
| **`search <terms>`** | Executes a search and prints formatted human-readable results. | `./searxng.sh search "guitar ir"` |
| **`search --json <q>`** | Executes a search and returns pretty-printed JSON. | `./searxng.sh search --json "ir"` |
| **`json <terms>`** | Shortcut to search and output raw JSON directly. | `./searxng.sh json "nam models"` |
| **`test`** | Runs the automated verification suite across categories. | `./searxng.sh test` |
| **`open`** | Opens the Web UI in your default browser. | `./searxng.sh open` |
| **`logs`** | Follows live container logs (`-f`). | `./searxng.sh logs` |

---

## JSON Mode

JSON mode is **enabled by default** in this installation. You can consume it in three ways:

### 1. Command-Line (`json` or `--json`)
Outputs pure, valid JSON suitable for piping into `jq`, storing to disk, or consuming in scripts:

```bash
# Pretty-printed JSON
./searxng.sh json "neural network dsp"

# Pipe into jq to inspect results
./searxng.sh json "audio dsp" | jq '.results[0:3] | .[].title'

# Using search with the --json flag
./searxng.sh search --json "cabinet impulse response"
```

### 2. HTTP REST API
Query the running instance directly via HTTP:

```bash
# Basic query returning JSON
curl -s "http://localhost:8080/search?q=convolution+reverb&format=json" | jq '.results[0]'

# Specific category (e.g. IT / code engines)
curl -s "http://localhost:8080/search?q=simd+avx2&categories=it&format=json"

# Autocomplete suggestions
curl -s "http://localhost:8080/autocompleter?q=neural+amp"
```

### 3. Python Integration
```python
import urllib.request, urllib.parse, json

def search_searxng(query, category="general"):
    params = {"q": query, "format": "json"}
    if category != "general":
        params["categories"] = category
    url = f"http://localhost:8080/search?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={"User-Agent": "NAM-Agent/1.0"})
    with urllib.request.urlopen(req) as response:
        return json.loads(response.read().decode("utf-8"))

results = search_searxng("guitar amp tone models")
print(results["results"][0]["title"])
```

---

## Architecture & Configuration

* **`core-config/settings.yml`**: Configures search engines, enables `json` and `html` formats, sets image proxying, and links to Valkey.
* **`docker-compose.yml`**: Manages `searxng-core` and `searxng-valkey` services.
* **`.env`**: Stores the cryptographic `secret_key` and active `SEARXNG_PORT`.
* **Port Memory**: If you run on a custom port (e.g. `SEARXNG_PORT=8888 ./searxng.sh start`), the port is remembered across all subsequent runs.
* **Port Reclamation**: If a previous run left a dangling container on your port, `./searxng.sh start` automatically reclaims it before starting.
