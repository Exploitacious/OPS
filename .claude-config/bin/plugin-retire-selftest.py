"""Exercise only deploy's retirement block, never its host setup or services.

Both deployers run under a throwaway HOME. The mock models the CLI's settings
writes; a real local CLI, when available, also checks the symlink boundary.
No API calls, real configuration changes, or plugin downloads.
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REAL_CLI = shutil.which("claude")
ENGINES = ["bash"] + (["pwsh"] if shutil.which("pwsh") else [])
MOCK = r"""#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
state_path = pathlib.Path(os.environ["RETIRE_STATE"])
state = json.loads(state_path.read_text())
with open(os.environ["RETIRE_RECORD"], "a") as out:
    out.write(json.dumps(args) + "\n")
if state.get("failure") == "inventory":
    sys.exit(7)
if args == ["plugin", "list", "--json"]:
    print(json.dumps(state["plugins"])); sys.exit(0)
if args == ["plugin", "marketplace", "list", "--json"]:
    print(json.dumps(state["markets"])); sys.exit(0)
# These mutations intentionally mirror the real CLI's settings behavior.
settings_path = pathlib.Path(os.environ["CLAUDE_CONFIG_DIR"]) / "settings.json"
settings = json.loads(settings_path.read_text())
if args[:2] == ["plugin", "uninstall"]:
    if state.get("failure") == "uninstall":
        print("uninstall failed", file=sys.stderr); sys.exit(7)
    plugin = args[2]
    if plugin in settings.get("enabledPlugins", {}):
        del settings["enabledPlugins"][plugin]
        settings_path.write_text(json.dumps(settings))
    state["plugins"] = [p for p in state["plugins"] if p["id"] != plugin]
elif args[:3] == ["plugin", "marketplace", "remove"]:
    name = args[3]
    if name not in settings.get("extraKnownMarketplaces", {}):
        print("not declared in user settings", file=sys.stderr); sys.exit(1)
    del settings["extraKnownMarketplaces"][name]
    settings_path.write_text(json.dumps(settings))
    state["markets"] = [p for p in state["markets"] if p["name"] != name]
else:
    sys.exit(8)
state_path.write_text(json.dumps(state))
"""


def retirement_script(engine):
    if engine == "bash":
        text = (ROOT / ".claude-config/deploy.sh").read_text()
        block = text.split(
            "# --- Claude Code plugins: retire caveman + ponytail ---", 1
        )[1]
        block = block.split("# --- Trust anchor ---", 1)[0]
        return (
            'set -euo pipefail\nmsg_ok() { echo OK:"$*"; }\nmsg_warn() { echo WARN:"$*"; }\nc_yel() { :; }\n'
            + block
        )
    text = (ROOT / ".claude-config/deploy.ps1").read_text()
    block = text.split("# --- Claude Code plugins: retire caveman + ponytail ---", 1)[1]
    block = block.split("# --- Git Bash pin + doctor", 1)[0]
    return (
        '$ErrorActionPreference = "Stop"\n'
        'function Write-Status {}\nfunction Write-Good { param($Text) "OK:$Text" }\n'
        'function Write-Warn { param($Text) "WARN:$Text" }\n'
        + block
        + '\nif ($ErrorActionPreference -ne "Stop") { throw "Error preference changed" }\n'
    )


class RetirementTests(unittest.TestCase):
    def run_case(
        self,
        engine,
        settings=None,
        plugins=None,
        markets=None,
        failure=None,
        real=False,
        shell_function=False,
    ):
        with tempfile.TemporaryDirectory(prefix="ops-retire-test-") as td:
            home = Path(td)
            config = home / ".claude"
            config.mkdir()
            source = home / "stage1-settings.json"
            source.write_text(json.dumps(settings if settings is not None else {}))
            (config / "settings.json").symlink_to(source)
            state = home / "state.json"
            state.write_text(
                json.dumps(
                    {
                        "plugins": plugins or [],
                        "markets": markets or [],
                        "failure": failure,
                    }
                )
            )
            record = home / "calls.jsonl"
            bin_dir = home / "bin"
            bin_dir.mkdir()
            cli = bin_dir / "claude"
            if real:
                cli.symlink_to(REAL_CLI)
                cache = config / "plugins/cache/caveman/caveman/1.0.0"
                (cache / ".claude-plugin").mkdir(parents=True)
                (cache / ".claude-plugin/plugin.json").write_text(
                    '{"name":"caveman","version":"1.0.0"}'
                )
                (config / "plugins/installed_plugins.json").write_text(
                    json.dumps(
                        {
                            "version": 2,
                            "plugins": {
                                "caveman@caveman": [
                                    {
                                        "scope": "user",
                                        "installPath": str(cache),
                                        "version": "1.0.0",
                                        "installedAt": "2026-10-18T00:00:00Z",
                                        "lastUpdated": "2026-10-18T00:00:00Z",
                                    }
                                ]
                            },
                        }
                    )
                )
            else:
                cli.write_text(MOCK)
                cli.chmod(0o755)
            env = dict(
                os.environ,
                HOME=td,
                CLAUDE_CONFIG_DIR=str(config),
                PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
                RETIRE_STATE=str(state),
                RETIRE_RECORD=str(record),
                DISABLE_AUTOUPDATER="1",
                CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1",
            )
            before = source.read_bytes()
            command = (
                ["bash"]
                if engine == "bash"
                else [
                    "pwsh",
                    "-NoLogo",
                    "-NoProfile",
                    "-NonInteractive",
                    "-Command",
                    "-",
                ]
            )
            script = retirement_script(engine)
            if shell_function:
                script = (
                    'function claude { throw "Do not invoke the shell shim" }\n'
                    + script
                )
            result = subprocess.run(
                command,
                input=script,
                env=env,
                cwd=td,
                text=True,
                capture_output=True,
                timeout=30,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(
                source.read_bytes(), before, "Stage-1 settings were changed"
            )
            self.assertTrue((config / "settings.json").is_symlink())
            calls = (
                [json.loads(line) for line in record.read_text().splitlines()]
                if record.exists()
                else []
            )
            mutations = [
                args for args in calls if "uninstall" in args or "remove" in args
            ]
            for args in mutations:
                self.assertEqual(args[-2:], ["--scope", "user"], args)
            if real:
                remaining = json.loads(
                    (config / "plugins/installed_plugins.json").read_text()
                )["plugins"]
            else:
                remaining = json.loads(state.read_text())["plugins"]
            return result.stdout + result.stderr, mutations, remaining

    def test_absent_is_a_quiet_noop(self):
        for engine in ENGINES:
            with self.subTest(engine=engine):
                output, mutations, _ = self.run_case(engine)
                self.assertFalse(mutations)
                self.assertNotIn("WARN:", output)

    def test_declarations_are_never_rewritten(self):
        for engine in ENGINES:
            for settings in (
                {"enabledPlugins": {"caveman@caveman": True}},
                {"enabledPlugins": {"caveman@caveman": False}},
                {
                    "extraKnownMarketplaces": {
                        "caveman": {
                            "source": {"source": "directory", "path": "/example"}
                        }
                    }
                },
            ):
                with self.subTest(engine=engine, settings=settings):
                    output, mutations, _ = self.run_case(
                        engine,
                        settings,
                        plugins=[{"id": "caveman@caveman", "scope": "user"}],
                        markets=[{"name": "caveman"}],
                    )
                    self.assertFalse(mutations)
                    self.assertIn("removal would edit Stage-1 settings", output)

    def test_undeclared_user_install_is_removed(self):
        for engine in ENGINES:
            with self.subTest(engine=engine):
                output, mutations, remaining = self.run_case(
                    engine, plugins=[{"id": "caveman@caveman", "scope": "user"}]
                )
                self.assertEqual(len(mutations), 1)
                self.assertFalse(remaining)
                self.assertIn("Removed retired plugin: caveman", output)

    def test_project_install_is_left_alone(self):
        for engine in ENGINES:
            with self.subTest(engine=engine):
                output, mutations, _ = self.run_case(
                    engine, plugins=[{"id": "caveman@caveman", "scope": "project"}]
                )
                self.assertFalse(mutations)
                self.assertIn("left unchanged to protect project settings", output)

    def test_inventory_failure_is_visible_and_nonfatal(self):
        for engine in ENGINES:
            with self.subTest(engine=engine):
                output, mutations, _ = self.run_case(engine, failure="inventory")
                self.assertFalse(mutations)
                self.assertIn("retirement skipped", output)

    def test_uninstall_failure_does_not_remove_marketplace(self):
        for engine in ENGINES:
            with self.subTest(engine=engine):
                output, mutations, remaining = self.run_case(
                    engine,
                    failure="uninstall",
                    plugins=[{"id": "caveman@caveman", "scope": "user"}],
                    markets=[{"name": "caveman"}],
                )
                self.assertEqual(len(mutations), 1)
                self.assertTrue(remaining)
                self.assertIn("could not be removed (rc=7)", output)

    def test_marketplace_failure_is_visible(self):
        for engine in ENGINES:
            with self.subTest(engine=engine):
                output, _, _ = self.run_case(engine, markets=[{"name": "caveman"}])
                self.assertIn("marketplace caveman remains (rc=1)", output)

    @unittest.skipUnless("pwsh" in ENGINES, "PowerShell is unavailable")
    def test_powershell_ignores_loaded_shell_function(self):
        output, mutations, remaining = self.run_case(
            "pwsh",
            plugins=[{"id": "caveman@caveman", "scope": "user"}],
            shell_function=True,
        )
        self.assertEqual(len(mutations), 1)
        self.assertFalse(remaining)
        self.assertIn("Removed retired plugin: caveman", output)

    @unittest.skipUnless(REAL_CLI, "local Claude CLI is unavailable")
    def test_real_cli_preserves_symlinked_settings(self):
        for engine in ENGINES:
            for declared in (False, True):
                with self.subTest(engine=engine, declared=declared):
                    settings = (
                        {"enabledPlugins": {"caveman@caveman": True}}
                        if declared
                        else {}
                    )
                    _, _, remaining = self.run_case(engine, settings, real=True)
                    self.assertEqual(bool(remaining.get("caveman@caveman")), declared)


if __name__ == "__main__":
    unittest.main(verbosity=2)
