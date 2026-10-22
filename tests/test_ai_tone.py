#!/usr/bin/env python3
"""AI contract parity, real Foundation validation/catalog tests, and MCP errors."""
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ToneTests(unittest.TestCase):
    def test_generated_contract(self):
        generator = load("generate", ROOT / "scripts/generate_rig_control_contract.py")
        self.assertEqual(generator.generate(), (ROOT / "src/rig_control_contract.h").read_text())

    @unittest.skipUnless(sys.platform == "darwin", "Foundation runtime requires macOS")
    def test_foundation_runtime(self):
        approved = os.environ.get("TMPDIR")
        with tempfile.TemporaryDirectory(prefix="axe-ai-test-", dir=approved) as temp:
            temp = Path(temp)
            root = temp / "library"
            for relative in ["Amp/A/clean.nam", "Amp/B/clean.nam", "Amp/C/unique.nam",
                             "Amp/Full/capture.nam", "Full Rig/Combo/rig.nam",
                             "Cab/CabA/mic.wav", "Cabinet/Legacy/old.wav", "Cab/Nam/cab.nam",
                             "Pedal/TS/ts9.nam"]:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("fixture")
            (root / "Amp/A/empty.nam").touch()
            (temp / "outside.nam").write_text("outside")
            (root / "Amp/A/outside.nam").symlink_to(temp / "outside.nam")
            (root / "Amp/A/_tone3000.json").write_text(json.dumps({"tone": {
                "title": "Boutique Clean", "description": "warm   clean\nboutique", "gear": "amp"},
                "downloads": [{"local_filename": "clean.nam", "original_model": {"name": "Clean capture"}}]}))
            (root / "Amp/Full/_tone3000.json").write_text(json.dumps({"tone": {"gear": "amp-cab"}}))
            binary = temp / "verify-ai"
            subprocess.run(["clang++", "-std=c++17", "-fobjc-arc", "-Isrc", "tests/verify_ai_support.mm",
                            "src/rig_ai_support.mm", "-framework", "Foundation", "-o", str(binary)], cwd=ROOT, check=True)
            subprocess.run([str(binary), str(root)], check=True)

    @unittest.skipUnless(sys.platform == "darwin" and bool(os.environ.get("RIG_UI_SO")), "Set RIG_UI_SO for built UI runtime checks")
    def test_built_ui_runtime(self):
        with tempfile.TemporaryDirectory(prefix="axe-ai-runtime-", dir=os.environ.get("TMPDIR")) as temp:
            binary = Path(temp) / "verify-runtime"
            subprocess.run(["clang++", "-std=c++20", "-fobjc-arc", "-Isrc", "-Ideps/lv2/include",
                            "tests/verify_ai_runtime.mm", "src/rig_knobs.cpp", "src/rig_theme.mm",
                            "-framework", "Cocoa", "-framework", "Security", "-framework", "QuartzCore",
                            "-framework", "CoreImage", "-o", str(binary)], cwd=ROOT, check=True)
            env = dict(os.environ, HOME=temp)
            subprocess.run([str(binary), str(Path(os.environ["RIG_UI_SO"]).resolve()), temp], env=env, check=True, timeout=30)

    @unittest.skipUnless(sys.platform == "darwin", "Foundation networking requires macOS")
    def test_provider_model_discovery(self):
        with tempfile.TemporaryDirectory(prefix="axe-ai-models-", dir=os.environ.get("TMPDIR")) as temp:
            binary = Path(temp) / "verify-models"
            cache = Path(temp) / "cache"
            subprocess.run(["clang++", "-std=c++17", "-fobjc-arc", "-Isrc",
                            "tests/verify_ai_model_catalog.mm", "src/rig_ai_model_catalog.mm",
                            "-framework", "Foundation", "-o", str(binary)], cwd=ROOT, check=True)
            subprocess.run([str(binary), str(cache)], check=True, timeout=30)

    def test_mcp_auth_preview_timeout_and_errors(self):
        mcp = load("axe_mcp", ROOT / "scripts/axe_fx_mcp.py")
        class Response:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self): return b'{"status":"ok"}'
        with patch.dict(os.environ, {"AXE_FX_API_TOKEN": "test-only"}), \
                patch.object(mcp.urllib.request, "urlopen", return_value=Response()) as request:
            mcp.handle_tool_call("axe_fx_ask_copilot", {"prompt": "clean"})
            req = request.call_args.args[0]
            self.assertEqual(req.get_header("Authorization"), "Bearer test-only")
            self.assertFalse(json.loads(req.data)["apply"])
            self.assertEqual(request.call_args.kwargs["timeout"], 135)
        with patch.dict(os.environ, {"AXE_FX_API_TOKEN": "test-only"}), \
                patch.object(mcp.urllib.request, "urlopen", side_effect=urllib.error.HTTPError(
                    "url", 400, "Bad", {}, io.BytesIO(b'{"message":"Invalid bass"}'))):
            self.assertIn("Invalid bass", mcp.http_post("controls", {"bass": 99})["error"])
        self.assertIn("error", mcp.handle_tool_call("axe_fx_set_knobs", []))
        schema = mcp.handle_tool_call
        with patch.object(mcp, "http_get", return_value={"status": "ok"}) as get:
            schema("axe_fx_get_control_schema", {})
            get.assert_called_once_with("controls/schema")


if __name__ == "__main__":
    unittest.main()
