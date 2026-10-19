#!/usr/bin/env python3
"""Pin bin/sandbox-lint's detection offline.

  LintUnitTests: the rules in sandbox-lint's header, one case each: which files
    are scanned (bin/tests, and every test or self-test elsewhere under
    .claude-config), what counts as a reference (code, not comments or
    docstrings; whole tokens only), where the guard must sit and the path it
    names (shell and Python, at any depth, from bin/tests, hooks/ or bin/
    itself), the static suite list, the needs verdict, and that an internal
    error is exit 2, never a verdict.

verify-ops.sh check 24 runs the lint over the real tree, and
verify-ops-selftest.sh pins that check against fixture suites. The private
harness this template comes from also drives a gate suite runner from it; OPS
has no suite runner.

The fixtures use a made-up tool name (fake-deleter), so this file names no real
destructive tool and runs anywhere, the sandbox included (a mutation run of the
lint: python3 sandbox-lint-test.py LintUnitTests).
"""
import os
import runpy
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

BIN = Path(__file__).resolve().parents[1]
LINT = BIN / "sandbox-lint"
L = runpy.run_path(str(LINT))
SH1, PY1 = L["guard_sh"](1), L["guard_py"](1)
TOOL = "fake-deleter"


class Root:
    """A throwaway checkout with .claude-config/bin/tests."""

    def __init__(self, test):
        tmp = tempfile.TemporaryDirectory()
        test.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.tests = self.root / ".claude-config/bin/tests"
        self.tests.mkdir(parents=True)

    def write(self, rel, text, mode=0o644):
        p = self.root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
        p.chmod(mode)
        return p

    def lint(self, *args, tools=(TOOL,), suites=()):
        cmd = [sys.executable, "-I", str(LINT), *args, "--root", str(self.root)]
        for t in tools:
            cmd += ["--tool", t]
        for s in suites:
            cmd += ["--suite", s]
        return subprocess.run(cmd, text=True, capture_output=True, timeout=60, check=False)

    def violations(self, **kw):
        r = self.lint("check", **kw)
        rows = [l.split("\t") for l in r.stdout.splitlines() if l.startswith("VIOLATION\t")]
        return r, {row[1]: row[2] for row in rows}


T = ".claude-config/bin/tests/"


class LintUnitTests(unittest.TestCase):
    def setUp(self):
        self.r = Root(self)

    def test_shell_reference_without_guard_is_a_violation(self):
        self.r.write(T + "a.sh", '#!/usr/bin/env bash\nset -uo pipefail\nS="$HERE/../%s"\n' % TOOL)
        r, v = self.r.violations()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertEqual(v, {T + "a.sh": "unguarded"})

    def test_shell_guard_first_after_shebang_comments_and_set_is_clean(self):
        for pre in ("", "# a comment\n\n", "set -euo pipefail\n", "# c\nset -e\nset -o pipefail\n"):
            with self.subTest(pre=pre):
                self.r.write(T + "a.sh", "#!/usr/bin/env bash\n%s%s\n%s --dry-run\n" % (pre, SH1, TOOL))
                r, v = self.r.violations()
                self.assertEqual((r.returncode, v), (0, {}), r.stdout + r.stderr)
                self.assertIn("SUMMARY\t1\t1\t1", r.stdout)

    def test_shell_guard_after_a_command_is_misplaced(self):
        self.r.write(T + "a.sh", "#!/bin/bash\nHERE=x\n%s\n%s\n" % (SH1, TOOL))
        _, v = self.r.violations()
        self.assertEqual(v, {T + "a.sh": "misplaced"})

    def test_shell_guard_inside_a_function_or_heredoc_does_not_count(self):
        self.r.write(T + "a.sh", "#!/bin/bash\nf() {\n%s\n}\n%s\n" % (SH1, TOOL))
        self.r.write(T + "b.sh", "#!/bin/bash\ncat <<EOF\n%s\nEOF\n%s\n" % (SH1, TOOL))
        _, v = self.r.violations()
        self.assertEqual(v, {T + "a.sh": "misplaced", T + "b.sh": "misplaced"})

    def test_shell_comment_reference_is_not_required(self):
        self.r.write(T + "a.sh", "#!/bin/bash\n# runs %s in the old days\n  # %s\necho hi\n" % (TOOL, TOOL))
        r, v = self.r.violations()
        self.assertEqual((r.returncode, v), (0, {}), r.stdout)
        self.assertIn("SUMMARY\t0\t0\t1", r.stdout)

    def test_shell_heredoc_reference_is_required(self):
        self.r.write(T + "a.sh", "#!/bin/bash\ncat > x <<'EOF'\nexec %s --apply\nEOF\n" % TOOL)
        _, v = self.r.violations()
        self.assertEqual(v, {T + "a.sh": "unguarded"})

    def test_reference_is_a_whole_token(self):
        refs = ['"%s"', "$HERE/../%s", "'%s'", "(%s)", "%s --apply", "x=%s"]
        not_refs = ["%s-test.sh", "%s.log", "x%s", "%s_x", "my-%s", "%s.d"]
        for i, form in enumerate(refs):
            self.r.write(T + "r%d.sh" % i, "#!/bin/bash\necho " + form % TOOL + "\n")
        for i, form in enumerate(not_refs):
            self.r.write(T + "n%d.sh" % i, "#!/bin/bash\necho " + form % TOOL + "\n")
        _, v = self.r.violations()
        self.assertEqual(sorted(v), sorted(T + "r%d.sh" % i for i in range(len(refs))))

    def test_python_docstring_and_comment_references_are_not_required(self):
        self.r.write(T + "a.py", '"""Tests for %s."""\nimport os  # %s\n\ndef f():\n    """%s again"""\n    return 1\n'
                     % (TOOL, TOOL, TOOL))
        r, v = self.r.violations()
        self.assertEqual((r.returncode, v), (0, {}), r.stdout)

    def test_python_code_reference_requires_the_guard(self):
        self.r.write(T + "a.py", '"""doc"""\nimport os\nTOOL = os.path.join("..", "%s")\n' % TOOL)
        _, v = self.r.violations()
        self.assertEqual(v, {T + "a.py": "unguarded"})

    def test_python_guard_after_docstring_or_future_import_is_clean(self):
        for pre in ("", '"""doc\n\nmore"""\n', '#!/usr/bin/env python3\n"""doc"""\nfrom __future__ import annotations\n'):
            with self.subTest(pre=pre):
                self.r.write(T + "a.py", '%s%s\nimport os\nTOOL = "%s"\n' % (pre, PY1, TOOL))
                r, v = self.r.violations()
                self.assertEqual((r.returncode, v), (0, {}), r.stdout + r.stderr)

    def test_python_guard_after_an_import_is_misplaced(self):
        self.r.write(T + "a.py", '"""doc"""\nimport json\n%s\nTOOL = "%s"\n' % (PY1, TOOL))
        _, v = self.r.violations()
        self.assertEqual(v, {T + "a.py": "misplaced"})

    def test_python_guard_with_a_different_path_is_not_the_guard(self):
        bad = PY1.replace('"sandbox_guard.py"', '"other.py"')
        self.r.write(T + "a.py", '%s\nTOOL = "%s"\n' % (bad, TOOL))
        _, v = self.r.violations()
        self.assertEqual(v, {T + "a.py": "unguarded"})

    def test_python_that_does_not_parse_counts_whole(self):
        self.r.write(T + "a.py", "# %s\ndef broken(:\n" % TOOL)
        _, v = self.r.violations()
        self.assertEqual(v, {T + "a.py": "unguarded"})

    def test_guard_depth_follows_the_directory(self):
        self.r.write(T + "sub/a.sh", "#!/bin/bash\n%s\n%s\n" % (L["guard_sh"](2), TOOL))
        self.r.write(T + "sub/b.sh", "#!/bin/bash\n%s\n%s\n" % (SH1, TOOL))
        self.r.write(T + "sub/c.py", '%s\nT = "%s"\n' % (L["guard_py"](2), TOOL))
        _, v = self.r.violations()
        self.assertEqual(v, {T + "sub/b.sh": "unguarded"})

    def test_what_is_scanned(self):
        self.r.write(T + "data.json", '{"tool": "%s"}\n' % TOOL)
        self.r.write(T + "notes.txt", "%s\n" % TOOL)
        self.r.write(T + "noext", "#!/bin/bash\n%s\n" % TOOL)
        self.r.write(T + "__pycache__/x.py", 'T = "%s"\n' % TOOL)
        r, v = self.r.violations()
        self.assertEqual(v, {T + "noext": "unguarded"})
        self.assertIn("SUMMARY\t1\t0\t1", r.stdout)

    def test_tests_outside_bin_tests_are_scanned_by_name_or_directory(self):
        C = ".claude-config/"
        sh, py = "#!/bin/bash\n\"$H/%s\"\n" % TOOL, 'TOOL = "%s"\n' % TOOL
        scanned = {"hooks/x-selftest.sh": sh, "remote-sessions/rc-selftest.sh": sh, "bin/y-selftest.sh": sh,
                   "bin/selftest": sh, "hooks/a-regression-test.py": py, "hooks/test_b.py": py,
                   "workflows/c.test.sh": sh, "remote-sessions/tests/w.sh": sh, "hooks/test/v.py": py}
        skipped = {"hooks/plain.sh": sh, "hooks/latest.sh": sh, "hooks/contest.py": py, "hooks/testing.sh": sh,
                   "hooks/x-selftest.txt": "%s\n" % TOOL, "remote-sessions/home/h.test.mjs": "// x\nrun('%s')\n" % TOOL,
                   "remote-sessions/home/node_modules/d-test.sh": sh, "hooks/__pycache__/e-test.py": py,
                   "hooks/.git/f-test.sh": sh}
        for rel, text in {**scanned, **skipped}.items():
            self.r.write(C + rel, text)
        self.r.write("SKILLS/g/scripts/g-selftest.sh", sh)   # outside .claude-config
        r, v = self.r.violations()
        self.assertEqual(v, {C + rel: "unguarded" for rel in scanned}, r.stdout + r.stderr)
        self.assertIn("SUMMARY\t%d\t0\t%d" % (len(scanned), len(scanned)), r.stdout)

    def test_guard_path_runs_from_the_file_to_bin(self):
        C = ".claude-config/"
        self.r.write(C + "hooks/a-selftest.sh", "#!/bin/bash\n%s\n%s\n" % (L["guard_sh"](["..", "bin"]), TOOL))
        self.r.write(C + "hooks/b-selftest.sh", "#!/bin/bash\n%s\n%s\n" % (SH1, TOOL))   # bin/tests' path, wrong here
        self.r.write(C + "bin/c-selftest.sh", "#!/bin/bash\nset -u\n%s\n%s\n" % (L["guard_sh"]([]), TOOL))
        self.r.write(C + "remote-sessions/home/d-test.py",
                     '%s\nT = "%s"\n' % (L["guard_py"](["..", "..", "bin"]), TOOL))
        self.r.write(C + "remote-sessions/e-test.py", '%s\nT = "%s"\n' % (PY1, TOOL))
        r, v = self.r.violations()
        self.assertEqual(v, {C + "hooks/b-selftest.sh": "unguarded", C + "remote-sessions/e-test.py": "unguarded"},
                         r.stdout + r.stderr)
        self.assertIn("SUMMARY\t5\t3\t5", r.stdout)
        # The guard names the real file: bin/sandbox-guard.sh from hooks/.
        self.assertIn("/../bin/sandbox-guard.sh\"", L["guard_sh"](["..", "bin"]))

    def test_static_suites(self):
        self.r.write(T + "plain.sh", "#!/bin/bash\necho no tool here\n")
        self.r.write(".claude-config/hooks/h.sh", "#!/bin/bash\n")
        _, v = self.r.violations(suites=(T + "plain.sh", T + "gone.sh", ".claude-config/hooks/h.sh"))
        self.assertEqual(v, {T + "plain.sh": "unguarded", T + "gone.sh": "missing",
                             ".claude-config/hooks/h.sh": "unscanned"})
        self.r.write(T + "plain.sh", "#!/bin/bash\n%s\necho no tool here\n" % SH1)
        r, v = self.r.violations(suites=(T + "plain.sh",))
        self.assertEqual((r.returncode, v), (0, {}), r.stdout)

    def test_needs(self):
        self.r.write(T + "ref.sh", "#!/bin/bash\n%s\n" % TOOL)
        self.r.write(T + "guarded.sh", "#!/bin/bash\n%s\necho\n" % SH1)
        self.r.write(T + "plain.sh", "#!/bin/bash\necho\n")
        self.r.write(T + "comment.sh", "#!/bin/bash\n# %s\n" % TOOL)
        self.r.write(".claude-config/hooks/x-selftest.sh", "#!/bin/bash\n\"$H/%s\"\n" % TOOL)
        want = {T + "ref.sh": "sandbox", T + "guarded.sh": "sandbox", T + "plain.sh": "bare",
                T + "comment.sh": "bare", ".claude-config/hooks/x-selftest.sh": "sandbox"}
        for rel, verdict in want.items():
            with self.subTest(rel=rel):
                r = self.r.lint("needs", rel)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(r.stdout.split("\t")[0], verdict, r.stdout)

    def test_errors_are_exit_2_never_a_verdict(self):
        r = self.r.lint("needs", T + "missing.sh")
        self.assertEqual((r.returncode, r.stdout), (2, ""), r.stderr)
        r = self.r.lint("check", tools=("bad name",))
        self.assertEqual(r.returncode, 2, r.stdout)
        r = self.r.lint("needs", T + "x.sh", suites=(T + "x.sh",))
        self.assertEqual(r.returncode, 2, r.stdout)
        self.r.write(T + "locked.sh", "#!/bin/bash\n", mode=0o000)
        r = self.r.lint("check")
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertNotIn("SUMMARY", r.stdout)


if __name__ == "__main__":
    unittest.main()
