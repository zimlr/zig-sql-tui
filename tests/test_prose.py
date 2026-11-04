import importlib.util
from pathlib import Path
import unittest

MODULE = Path(__file__).resolve().parent.parent / "tools/check_prose.py"
spec = importlib.util.spec_from_file_location("check_prose", MODULE)
check_prose = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_prose)


class ProseCheckTests(unittest.TestCase):
    def test_flags_prohibited_prose(self):
        text = "We provide a bulletproof tool!\nIs this safe?\nUse this; continue.\n"
        errors = check_prose.check_text(text)
        self.assertEqual({line for line, _ in errors}, {1, 2, 3})

    def test_ignores_code_and_link_targets(self):
        text = "Use `SELECT 1;` and [the reference](https://example.invalid/a?b=c).\n```sql\nSELECT 1;\n```\n"
        self.assertEqual(check_prose.check_text(text), [])

    def test_flags_unclosed_fences(self):
        self.assertTrue(check_prose.check_text("```sh\necho test\n"))


if __name__ == "__main__":
    unittest.main()
