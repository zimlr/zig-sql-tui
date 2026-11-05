import os
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest

from test_recovery import EXE, ROOT, TMP
from test_termux_restrictions import restrict

DEBUG_EXE = os.environ.get("ZSQT_DEBUG_EXE")


class ProductionDiagnosticsTests(unittest.TestCase):
    def test_production_build_does_not_run_self_test(self):
        result = subprocess.run([EXE, "--debug-test", "--confirm"], capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"only in a diagnostics build", result.stderr)


@unittest.skipUnless(DEBUG_EXE, "diagnostics build was not supplied")
class DiagnosticsTests(unittest.TestCase):
    def setUp(self):
        TMP.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=TMP)
        self.home = Path(self.temp.name) / "home"
        self.home.mkdir()
        self.user_database = self.home / "untouched.sqlite"
        self.user_database.write_bytes(b"do not modify")
        self.env = {**os.environ, "HOME": str(self.home)}

    def tearDown(self):
        self.temp.cleanup()

    def run_debug(self, *args, preexec_fn=None):
        return subprocess.run([DEBUG_EXE, *args], env=self.env, capture_output=True,
                              preexec_fn=preexec_fn, timeout=30)

    def assert_passed(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for name in (b"ROLLBACK WRITE", b"WAL", b"RECOVERY", b"CLEANUP", b"RESULT"):
            self.assertIn(name + b": PASS", result.stdout)
        self.assertEqual(self.user_database.read_bytes(), b"do not modify")
        self.assertEqual(list((self.home / ".zsqt").iterdir()), [])

    def test_confirmation_required_without_creating_files(self):
        for args in (("--debug-test",), ("--debug-test", "--confirm", "extra")):
            with self.subTest(args=args):
                result = self.run_debug(*args)
                self.assertEqual(result.returncode, 2)
                self.assertIn(b"--debug-test --confirm", result.stderr)
                self.assertFalse((self.home / ".zsqt").exists())
        self.assertEqual(self.user_database.read_bytes(), b"do not modify")

    def test_self_test_and_cleanup(self):
        self.assert_passed(self.run_debug("--debug-test", "--confirm"))
        self.assert_passed(self.run_debug("--debug-test", "--confirm"))

    @unittest.skipUnless(platform.system() == "Linux" and platform.machine() in ("x86_64", "aarch64"), "Linux seccomp is required")
    def test_self_test_under_restricted_syscalls(self):
        child = os.fork()
        if child == 0:
            try:
                restrict()
            except OSError:
                os._exit(77)
            os._exit(0)
        _, status = os.waitpid(child, 0)
        if os.waitstatus_to_exitcode(status) == 77:
            self.skipTest("seccomp filters are not permitted in this environment")
        self.assertEqual(os.waitstatus_to_exitcode(status), 0)
        self.assert_passed(self.run_debug("--debug-test", "--confirm", preexec_fn=restrict))

    def test_rejects_symlinked_home_and_config(self):
        other = self.home / "other"
        other.mkdir()
        (self.home / ".zsqt").symlink_to(other, target_is_directory=True)
        result = self.run_debug("--debug-test", "--confirm")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"SETUP: FAIL", result.stdout)
        self.assertEqual(list(other.iterdir()), [])
        self.assertEqual(self.user_database.read_bytes(), b"do not modify")
        (self.home / ".zsqt").unlink()
        alias = self.home.parent / "home-alias"
        alias.symlink_to(self.home, target_is_directory=True)
        self.env["HOME"] = str(alias)
        result = self.run_debug("--debug-test", "--confirm")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"SETUP: FAIL", result.stdout)
        self.assertFalse((self.home / ".zsqt").exists())

    def test_rejects_writable_home_directory(self):
        self.home.chmod(0o777)
        result = self.run_debug("--debug-test", "--confirm")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"SETUP: FAIL", result.stdout)
        self.assertFalse((self.home / ".zsqt").exists())
        self.assertEqual(self.user_database.read_bytes(), b"do not modify")

    def test_rejects_writable_config_directory(self):
        config = self.home / ".zsqt"
        config.mkdir(mode=0o700)
        config.chmod(0o777)
        result = self.run_debug("--debug-test", "--confirm")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"SETUP: FAIL", result.stdout)
        self.assertEqual(list(config.iterdir()), [])
        self.assertEqual(self.user_database.read_bytes(), b"do not modify")


if __name__ == "__main__":
    unittest.main()
