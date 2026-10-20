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
import urllib.request
import urllib.error
import urllib.parse

AXE_FX_API_BASE = "http://127.0.0.1:48920/api/v1"

def http_get(endpoint, params=None):
    url = f"{AXE_FX_API_BASE}/{endpoint}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": "AxeFX-MCP/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.URLError as e:
        return {
            "error": f"Failed to connect to Axe FX: {e}. Ensure the Axe FX standalone app is running."
        }

def http_post(endpoint, payload):
    url = f"{AXE_FX_API_BASE}/{endpoint}"
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json", "User-Agent": "AxeFX-MCP/1.0"}
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.URLError as e:
        return {
            "error": f"Failed to connect to Axe FX: {e}. Ensure the Axe FX standalone app is running."
        }

TOOLS = [
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
        "description": "Load a preset by name into Axe FX (e.g. 'Slipknot (Mick Thompson)', 'Lamb of God', 'Architects').",
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
        "description": "Query the in-app AI Tone Copilot with a plain-English request (e.g. 'Mick Thomson Before I Forget, no feedback', 'Tighten low end for drop-D', 'Diagnose feedback'). Optionally apply the parameters immediately to the live rig.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "prompt": {
                    "type": "string",
                    "description": "The tone description, artist, song, or acoustic problem."
                },
                "apply": {
                    "type": "boolean",
                    "description": "Whether to immediately apply the suggested settings to the live running rig (default true).",
                    "default": True
                }
            },
            "required": ["prompt"]
        }
    }
]

def handle_tool_call(tool_name, arguments):
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
        apply = arguments.get("apply", True)
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
        except Exception as e:
            continue

        req_id = req.get("id")
        method = req.get("method")
        params = req.get("params", {})

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
                "isError": "error" in result_data
            })

        elif method == "ping":
            send_response(req_id, {})

        else:
            if req_id is not None:
                send_error(req_id, -32601, f"Method '{method}' not found")

if __name__ == "__main__":
    main()
