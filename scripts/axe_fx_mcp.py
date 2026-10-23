#!/usr/bin/env python3
"""
axe_fx_mcp.py — Universal Model Context Protocol (MCP) Server for Axe FX.

Provides seamless tool-calling integration for:
- Gemini / Antigravity
- Claude / Claude Code
- OpenAI / Codex

Connects over local loopback HTTP to the running Axe FX standalone instance (http://127.0.0.1:48920).
Zero external dependencies (uses standard Python 3 urllib and json).
"""

import sys
import json
import os
import socket
from pathlib import Path
import urllib.request
import urllib.error
import urllib.parse

AXE_FX_API_BASE = "http://127.0.0.1:48920/api/v1"

def request_headers():
    token = os.environ.get("AXE_FX_API_TOKEN")
    if not token:
        try:
            token = (Path.home() / "Library/Application Support/Axe FX/local-api-token").read_text().strip()
        except OSError:
            raise ValueError("Local API token not found. Start Axe FX or set AXE_FX_API_TOKEN.")
    return {"Authorization": f"Bearer {token}", "User-Agent": "AxeFX-MCP/1.0"}

def fetch_json(url, payload=None, timeout=10):
    try:
        headers = request_headers()
        data = None if payload is None else json.dumps(payload, allow_nan=False).encode("utf-8")
        if data is not None:
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, headers=headers)
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            result = json.loads(resp.read().decode("utf-8"))
            if not isinstance(result, dict):
                return {"error": "Axe FX returned a non-object response."}
            if result.get("status") == "error":
                result["error"] = result.get("message", "Axe FX request failed.")
            return result
    except urllib.error.HTTPError as error:
        try:
            detail = json.loads(error.read().decode("utf-8")).get("message", str(error))
        except (ValueError, UnicodeError):
            detail = str(error)
        return {"error": f"Axe FX HTTP {error.code}: {detail}"}
    except (urllib.error.URLError, socket.timeout, OSError, ValueError, UnicodeError) as error:
        return {"error": f"Axe FX request failed: {error}"}

def http_get(endpoint, params=None):
    url = f"{AXE_FX_API_BASE}/{endpoint}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    return fetch_json(url)

def http_post(endpoint, payload):
    url = f"{AXE_FX_API_BASE}/{endpoint}"
    return fetch_json(url, payload, timeout=135 if endpoint == "ai/prompt" else 15)

TOOLS = [
    {
        "name": "axe_fx_get_control_schema",
        "description": "Read valid control names, ranges, ENGINE units and enum IDs before adjusting knobs. Percentages are 0..100; EQ trims are dB, neutral 0.",
        "inputSchema": {"type": "object", "properties": {}}
    },
    {
        "name": "axe_fx_ping",
        "description": "Check if the Axe FX standalone application is running and accessible.",
        "inputSchema": {
            "type": "object",
            "properties": {}
        }
    },
    {
        "name": "axe_fx_get_rig_state",
        "description": "Get the complete current state of the running Axe FX guitar rig: active preset name, all knob/slider/toggle control values, active amp/cab IR models, and input meters.",
        "inputSchema": {
            "type": "object",
            "properties": {}
        }
    },
    {
        "name": "axe_fx_set_knobs",
        "description": "Adjust one or more knobs, sliders, or toggles in Axe FX live in real-time. Supports control names (e.g. 'bass', 'mid', 'treble', 'gate_threshold', 'input_eq', 'od_drive', 'od_tone', 'od_level', 'compressor_enabled', 'master', 'presence', 'delay_mix', etc.).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "controls": {
                    "type": "object",
                    "description": "Key-value dictionary of control names and their target float values.",
                    "additionalProperties": { "type": "number" }
                }
            },
            "required": ["controls"]
        }
    },
    {
        "name": "axe_fx_load_amp_model",
        "description": "Load a NAM amplifier model capture (.nam) into Stage 1 from a path or filename in the Tone3000 library.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "model": {
                    "type": "string",
                    "description": "The exact path or filename of the .nam amp model (e.g. '[AMP] TREC-150BLD-DIO-MDN Gobsmacked - DI [REVyHI].nam' or 'Fast Aggressive.nam')."
                }
            },
            "required": ["model"]
        }
    },
    {
        "name": "axe_fx_load_cab_ir",
        "description": "Load a cabinet impulse response (.wav) into Stage 2 from a path or filename in the Tone3000 library.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "cab": {
                    "type": "string",
                    "description": "The exact path or filename of the .wav cabinet IR (e.g. 'Orange 4x12 V30 shure57 cn.wav')."
                }
            },
            "required": ["cab"]
        }
    },
    {
        "name": "axe_fx_get_presets",
        "description": "List all available presets in Axe FX and see which preset is currently loaded.",
        "inputSchema": {
            "type": "object",
            "properties": {}
        }
    },
    {
        "name": "axe_fx_load_preset",
        "description": "Load a preset by name into Axe FX (e.g. 'Slipknot (Mick Thompson)', 'Lamb of God', 'Architects'). If created with AI Tone Copilot, returns its AI metadata and token cost.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "The preset name to load."
                }
            },
            "required": ["name"]
        }
    },
    {
        "name": "axe_fx_save_preset",
        "description": "Save the current rig settings as a preset file.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Name for the saved preset."
                }
            },
            "required": ["name"]
        }
    },
    {
        "name": "axe_fx_search_library",
        "description": "Search the local Tone3000 library (~/Music/Tone3000 Library) for amp captures (.nam) and cabinet IRs (.wav).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Search keyword (e.g. 'rectifier', 'rivera', '5150', 'v30', 'orange', 'bogner')."
                }
            },
            "required": ["query"]
        }
    },
    {
        "name": "axe_fx_ask_copilot",
        "description": "Query the in-app AI Tone Copilot with a plain-English request (e.g. 'Mick Thomson Before I Forget, no feedback', 'Tighten low end for drop-D', 'Diagnose feedback'). Optionally apply the parameters immediately to the live rig. Returns proposed settings, input/output token counts, and token cost in USD.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "prompt": {
                    "type": "string",
                    "description": "The tone description, artist, song, or acoustic problem."
                },
                "apply": {
                    "type": "boolean",
                    "description": "Whether to apply the suggestion to the live rig. Default false: preview first.",
                    "default": False
                }
            },
            "required": ["prompt"]
        }
    }
]

def handle_tool_call(tool_name, arguments):
    if not isinstance(arguments, dict):
        return {"error": "Tool arguments must be an object."}
    if tool_name == "axe_fx_get_control_schema":
        return http_get("controls/schema")
    if tool_name == "axe_fx_ping":
        return http_get("ping")

    elif tool_name == "axe_fx_get_rig_state":
        return http_get("state")

    elif tool_name == "axe_fx_set_knobs":
        controls = arguments.get("controls", {})
        return http_post("controls", controls)

    elif tool_name == "axe_fx_load_amp_model":
        model = arguments.get("model", "")
        return http_post("models/load", {"stage": 1, "amp": model})

    elif tool_name == "axe_fx_load_cab_ir":
        cab = arguments.get("cab", "")
        return http_post("models/load", {"stage": 2, "cab": cab})

    elif tool_name == "axe_fx_get_presets":
        return http_get("presets")

    elif tool_name == "axe_fx_load_preset":
        name = arguments.get("name", "")
        return http_post("presets/load", {"name": name})

    elif tool_name == "axe_fx_save_preset":
        name = arguments.get("name", "")
        return http_post("presets/save", {"name": name})

    elif tool_name == "axe_fx_search_library":
        q = arguments.get("query", "")
        return http_get("library/search", {"q": q})

    elif tool_name == "axe_fx_ask_copilot":
        prompt = arguments.get("prompt", "")
        apply = arguments.get("apply", False)
        return http_post("ai/prompt", {"prompt": prompt, "apply": apply})

    else:
        return {"error": f"Unknown tool: {tool_name}"}

def send_response(req_id, result):
    response = {
        "jsonrpc": "2.0",
        "id": req_id,
        "result": result
    }
    sys.stdout.write(json.dumps(response) + "\n")
    sys.stdout.flush()

def send_error(req_id, code, message):
    response = {
        "jsonrpc": "2.0",
        "id": req_id,
        "error": {
            "code": code,
            "message": message
        }
    }
    sys.stdout.write(json.dumps(response) + "\n")
    sys.stdout.flush()

def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except (ValueError, UnicodeError):
            send_error(None, -32700, "Invalid JSON")
            continue

        if not isinstance(req, dict):
            send_error(None, -32600, "Request must be an object")
            continue
        req_id = req.get("id")
        method = req.get("method")
        params = req.get("params", {})
        if not isinstance(params, dict):
            send_error(req_id, -32602, "params must be an object")
            continue

        if method == "initialize":
            send_response(req_id, {
                "protocolVersion": "2024-11-05",
                "capabilities": {
                    "tools": {}
                },
                "serverInfo": {
                    "name": "axe-fx-mcp",
                    "version": "1.0.0"
                }
            })

        elif method == "notifications/initialized":
            pass

        elif method == "tools/list":
            send_response(req_id, {
                "tools": TOOLS
            })

        elif method == "tools/call":
            tool_name = params.get("name")
            arguments = params.get("arguments", {})
            result_data = handle_tool_call(tool_name, arguments)
            text_repr = json.dumps(result_data, indent=2)
            send_response(req_id, {
                "content": [
                    {
                        "type": "text",
                        "text": text_repr
                    }
                ],
                "isError": "error" in result_data or result_data.get("status") == "error"
            })

        elif method == "ping":
            send_response(req_id, {})

        else:
            if req_id is not None:
                send_error(req_id, -32601, f"Method '{method}' not found")

if __name__ == "__main__":
    main()
