import ctypes
import importlib.util
import os
from pathlib import Path
import platform
import signal
import unittest

MODULE = Path(__file__).resolve().parent.parent / "tools/check_termux_candidate.py"
spec = importlib.util.spec_from_file_location("check_termux_candidate", MODULE)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


@unittest.skipUnless(platform.system() == "Linux" and platform.machine() in ("x86_64", "aarch64"), "Linux seccomp is required")
class TermuxProbeTests(unittest.TestCase):
    def test_filter_traps_the_requested_syscall(self):
        child = os.fork()
        if child == 0:
            try:
                probe.trap_syscall(437)
            except OSError:
                os._exit(77)
            ctypes.CDLL(None).syscall(437, -100, 0, 0, 0)
            os._exit(0)
        _, status = os.waitpid(child, 0)
        code = os.waitstatus_to_exitcode(status)
        if code == 77:
            self.skipTest("seccomp filters are not permitted in this environment")
        self.assertEqual(code, -signal.SIGSYS)


if __name__ == "__main__":
    unittest.main()
