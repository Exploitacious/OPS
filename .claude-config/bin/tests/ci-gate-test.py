#!/usr/bin/env python3
"""Exercise the CI JavaScript check against source, without running that source."""

import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
GATE = ROOT / ".github/workflows/gate.yml"


def javascript_step():
    """Read this literal run block without adding a YAML package dependency."""
    lines = GATE.read_text().splitlines()
    start = lines.index("      - name: Check every JavaScript script")
    start = lines.index("        run: |", start) + 1
    body = []
    for line in lines[start:]:
        if line and not line.startswith("          "):
            break
        body.append(line[10:])
    return "\n".join(body) + "\n"


class JavaScriptGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # sandbox-run gives the suite a fresh HOME, so a node installed under
        # the real one (nvm, fnm) is not on PATH there. Locally that is a skip
        # with the way out; in GitHub Actions it is a failure, so the gate can
        # never pass this suite without running it.
        if shutil.which("node"):
            return
        if os.environ.get("GITHUB_ACTIONS") == "true":
            raise RuntimeError("node is not on PATH in CI: the JavaScript check cannot be tested")
        raise unittest.SkipTest(
            "node is not on PATH here (under sandbox-run, a node installed in "
            "your HOME is hidden); run python3 -B "
            ".claude-config/bin/tests/ci-gate-test.py outside the sandbox"
        )

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.runner = self.root / "runner"
        self.runner.mkdir()

    def check(self, files):
        for name, source in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(textwrap.dedent(source))
        (self.runner / "node.lst").write_text("".join(name + "\n" for name in files))
        return subprocess.run(
            [
                "bash",
                "--noprofile",
                "--norc",
                "-eo",
                "pipefail",
                "-c",
                javascript_step(),
            ],
            cwd=self.root,
            env={**os.environ, "RUNNER_TEMP": str(self.runner)},
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )

    def assert_result(self, result, valid):
        self.assertEqual(result.returncode == 0, valid, result.stdout + result.stderr)

    def test_every_tracked_javascript_file_passes(self):
        # The step over the repository's own .js files, so a checker change that
        # rejects a shipped script fails here, not first on the hosted runner.
        # This covers the skill-bundled workflow SKILLS/memory-prune/
        # audit_workflow.js, which a path rule once sent to the module check.
        listed = subprocess.run(
            ["git", "-C", str(ROOT), "ls-files", "-z", "*.js"],
            capture_output=True,
            text=True,
            check=False,
        )
        if listed.returncode == 0:
            names = [name for name in listed.stdout.split("\0") if name]
        else:
            names = [
                str(path.relative_to(ROOT))
                for path in sorted(ROOT.rglob("*.js"))
                if ".git" not in path.relative_to(ROOT).parts
            ]
        files = {name: (ROOT / name).read_text() for name in names}
        self.assertIn("SKILLS/memory-prune/audit_workflow.js", files)
        self.assert_result(self.check(files), True)

    def test_workflow_outside_the_workflows_directory(self):
        self.assert_result(
            self.check(
                {
                    "SKILLS/demo/audit_workflow.js": """
            // A skill-bundled workflow script.
            export const meta = { name: 'demo' };
            const value = await Promise.resolve(1);
            return value;
        """
                }
            ),
            True,
        )

    def test_module_exporting_meta_later_is_an_ordinary_module(self):
        # Only a leading `export const meta =` makes a workflow script.
        self.assert_result(
            self.check(
                {
                    "ordinary.js": """
            import fs from 'node:fs';
            export const meta = { fs };
        """
                }
            ),
            True,
        )

    def test_valid_workflow_await_and_return(self):
        self.assert_result(
            self.check(
                {
                    ".claude-config/workflows/valid.js": """
            export const meta = {};
            const value = await Promise.resolve(1);
            return value;
        """
                }
            ),
            True,
        )

    def test_workflow_shebang_comments_and_indented_metadata(self):
        source = (
            "#!/usr/bin/env node\n// Heading\n/* Multiple\nlines */\n"
            "  export const meta = {};\nreturn await Promise.resolve(1);\n"
        )
        self.assert_result(
            self.check({".claude-config/workflows/valid.js": source}), True
        )

    def test_nested_metadata_export_remains_invalid(self):
        source = "function nested() {\nexport const meta = {};\n}\n"
        self.assert_result(
            self.check({".claude-config/workflows/broken.js": source}), False
        )

    def test_workflow_cannot_escape_a_textual_wrapper(self):
        # A wrapper around this invalid body becomes two valid functions.
        self.assert_result(
            self.check(
                {
                    ".claude-config/workflows/broken.js": """
            export const meta = {};
            })
            ;(async () => {
            return 1;
        """
                }
            ),
            False,
        )

    def test_malformed_export_is_not_stripped(self):
        self.assert_result(
            self.check(
                {
                    ".claude-config/workflows/broken.js": """
            export const meta = {};
            export if (true) {}
        """
                }
            ),
            False,
        )

    def test_valid_commonjs_await_identifier(self):
        self.assert_result(
            self.check({"ordinary.js": "var await = 1;\nconsole.log(await);\n"}), True
        )

    def test_valid_es_module(self):
        self.assert_result(
            self.check(
                {
                    "ordinary.js": """
            import fs from 'node:fs';
            export default await Promise.resolve(fs);
        """
                }
            ),
            True,
        )

    def test_broken_es_module_fails_before_a_valid_file(self):
        self.assert_result(
            self.check(
                {
                    "broken.js": "export const value = {\n",
                    "valid.js": "const value = 1;\n",
                }
            ),
            False,
        )

    def test_broken_module_with_import(self):
        self.assert_result(
            self.check(
                {
                    "ordinary.js": """
            import fs from 'node:fs';
            export const value = {
        """
                }
            ),
            False,
        )

    def test_static_import_cannot_hide_a_broken_workflow(self):
        self.assert_result(
            self.check(
                {
                    ".claude-config/workflows/broken.js": """
            export const meta = {};
            import fs from 'node:fs';
            const value = {
        """
                }
            ),
            False,
        )

    def test_unclosed_workflow_body(self):
        self.assert_result(
            self.check(
                {
                    ".claude-config/workflows/broken.js": """
            export const meta = {};
            if (true) {
        """
                }
            ),
            False,
        )

    def test_source_is_not_executed(self):
        source = "require('node:fs').writeFileSync('executed', 'bad');\n"
        self.assert_result(
            self.check(
                {
                    "ordinary.js": source,
                    ".claude-config/workflows/valid.js": "export const meta = {};\n"
                    + source,
                }
            ),
            True,
        )
        self.assertFalse((self.root / "executed").exists())


if __name__ == "__main__":
    unittest.main()
