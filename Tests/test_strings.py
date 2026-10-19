import importlib.util
import pathlib
import subprocess
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Tools" / "check_strings.py"
BUNDLE = ROOT / "Resources" / "YTKACE.bundle"


def _load_module():
    spec = importlib.util.spec_from_file_location("check_strings", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("check_strings", module)
    spec.loader.exec_module(module)
    return module


cs = _load_module()


class StringsParserTests(unittest.TestCase):
    def test_parses_escapes_comments_and_multiline_values(self):
        text = (
            '/* header */\n'
            '// line comment\n'
            '"a" = "A";\n'
            '"quote \\"x\\"" = "Q \\"x\\"";\n'
            '"nl\\n" /* inline */ = "line1\nline2";\n'
            '"uni" = "\\U00e9\\u00E9";\n'
            '"short";\n'
        )
        entries = cs.parse_strings_text(text).entries
        self.assertEqual(entries["a"], "A")
        self.assertEqual(entries['quote "x"'], 'Q "x"')
        self.assertEqual(entries["nl\n"], "line1\nline2")
        self.assertEqual(entries["uni"], "éé")
        self.assertEqual(entries["short"], "short")

    def test_reports_duplicates(self):
        table = cs.parse_strings_text('"a\\n" = "1";\n"a\n" = "2";\n')
        self.assertEqual(table.duplicates, ["a\n"])
        self.assertEqual(table.entries["a\n"], "2")

    def test_rejects_malformed_input(self):
        with self.assertRaises(cs.StringsParseError):
            cs.parse_strings_text('"a" = "b"\n"c" = "d";')
        with self.assertRaises(cs.StringsParseError):
            cs.parse_strings_text('"a" = "unterminated;')

    def test_placeholders(self):
        self.assertEqual(cs.placeholders("%@ of %ld"), cs.placeholders("%2$ld sur %1$@"))
        self.assertEqual(cs.placeholders("100%% %.2f %lu"), {"f": 1, "lu": 1})
        self.assertNotEqual(cs.placeholders("%@ %d"), cs.placeholders("%@ %@"))
        self.assertNotEqual(cs.placeholders("%lu"), cs.placeholders("%d"))

    def test_check_detects_problems(self):
        def table(entries):
            t = cs.StringsTable(path="mem")
            t.entries = dict(entries)
            return t

        report = cs.check({
            "en": table({"A %@": "A %@", "B": "B", "C %d": "C %d"}),
            "xx": table({"A %@": "A %@ %@", "C %d": "C %1$d", "Z": "Z"}),
        })
        self.assertFalse(report.ok)
        self.assertEqual(report.missing["xx"], ["B"])
        self.assertEqual(report.extra["xx"], ["Z"])
        self.assertEqual([m[0] for m in report.placeholder_mismatches["xx"]], ["A %@"])


class LocalizationTablesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tables = cs.load_bundle(str(BUNDLE))
        cls.report = cs.check(cls.tables)

    def test_base_language_present(self):
        self.assertIn(cs.BASE_LANGUAGE, self.tables)
        self.assertGreater(len(self.tables[cs.BASE_LANGUAGE].entries), 0)
        self.assertGreater(len(self.tables), 1)

    def test_no_missing_keys(self):
        missing = {lang: keys for lang, keys in self.report.missing.items() if keys}
        self.assertEqual(missing, {}, cs.format_report(self.report, quiet=True))

    def test_no_extra_keys(self):
        extra = {lang: keys for lang, keys in self.report.extra.items() if keys}
        self.assertEqual(extra, {}, cs.format_report(self.report, quiet=True))

    def test_no_placeholder_mismatches(self):
        mism = {lang: m for lang, m in self.report.placeholder_mismatches.items() if m}
        self.assertEqual(mism, {}, cs.format_report(self.report, quiet=True))
        self.assertEqual(self.report.base_placeholder_issues, [])

    def test_no_duplicate_keys(self):
        dups = {lang: keys for lang, keys in self.report.duplicates.items() if keys}
        self.assertEqual(dups, {}, cs.format_report(self.report, quiet=True))

    def test_cli_exit_status(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--quiet", "--bundle", str(BUNDLE)],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
