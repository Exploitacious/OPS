#!/usr/bin/env python3
"""Inherited file and directory descriptors must not bypass sandbox mounts.

Run outside sandbox-run, like sandbox-run-test.sh. Each attempted write names
only this test's canary under /var/tmp; even a broken runner cannot reach any
other file. High descriptors avoid the runner's nonce descriptor (3).
"""
import fcntl
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

RUNNER = Path(__file__).resolve().parents[1] / "sandbox-run"
PYTHON = shutil.which("python3", path="/usr/local/bin:/usr/bin:/bin")
PROBE = """
import errno, os, sys
assert os.environ.get('OPS_SANDBOX') == '1'
fd = int(sys.argv[1])
try:
    if sys.argv[2] == 'directory':
        fd = os.open('canary', os.O_WRONLY | os.O_TRUNC, dir_fd=fd)
    os.write(fd, b'escaped')
except OSError as exc:
    if exc.errno != errno.EBADF:
        raise
    print('closed')
else:
    print('leaked')
"""


class InheritedDescriptorTests(unittest.TestCase):
    def check_descriptor(self, directory, minimum):
        with tempfile.TemporaryDirectory(prefix="sandbox-fd-test-", dir="/var/tmp") as tmp:
            canary = Path(tmp) / "canary"
            canary.write_text("original")
            source = os.open(tmp, os.O_RDONLY | os.O_DIRECTORY) if directory else os.open(canary, os.O_RDWR)
            try:
                fd = fcntl.fcntl(source, fcntl.F_DUPFD, minimum)
            finally:
                os.close(source)
            try:
                result = subprocess.run(
                    [str(RUNNER), "--no-net", "--chdir", "/var/tmp", "--", PYTHON,
                     "-I", "-c", PROBE, str(fd), "directory" if directory else "file"],
                    pass_fds=(fd,), capture_output=True, text=True, timeout=15, check=False,
                )
            finally:
                os.close(fd)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(canary.read_text(), "original", "inherited descriptor wrote through the sandbox")
            self.assertEqual(result.stdout.strip(), "closed")

    def test_inherited_writable_file_is_closed(self):
        for minimum in (9, 99, 255, 300):
            with self.subTest(minimum=minimum):
                self.check_descriptor(directory=False, minimum=minimum)

    def test_inherited_directory_cannot_open_a_host_file(self):
        for minimum in (9, 99, 255, 300):
            with self.subTest(minimum=minimum):
                self.check_descriptor(directory=True, minimum=minimum)


if __name__ == "__main__":
    unittest.main()
