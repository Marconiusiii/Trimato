"""Run with PYTHONDONTWRITEBYTECODE=1 python3 BackgroundChecks/test_help_build.py."""
import importlib.util
from pathlib import Path
import plistlib
import re
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('help_build', ROOT / 'Trimato/build-help.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class HelpBuildTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='trimato-help-build-')
        self.root = Path(self.scratch.name)
        self.source = self.root / 'Source.help'
        shutil.copytree(ROOT / 'Trimato/Trimato/Trimato.help', self.source)
        self.output = self.root / 'Generated'

    def tearDown(self):
        self.scratch.cleanup()

    def generate(self, version='1.7.0', build='3'):
        builder.generate(self.source, self.output, version, build)
        return plistlib.loads((self.output / 'Trimato.help/Contents/Info.plist').read_bytes())

    def test_registered_topics_match_swift_destinations(self):
        topics = plistlib.loads(
            (self.source / 'Contents/Resources/HelpTopics.plist').read_bytes())
        swift = (ROOT / 'Trimato/Trimato/TrimatoHelp.swift').read_text()
        cases = set(re.findall(r'case \w+ = "(trimato-[^"]+)"', swift))
        self.assertEqual(cases, set(topics))
        self.generate()
        builder.validate_indexes(self.output / 'Trimato.help', topics)

    def test_all_generated_pages_are_declared_for_sandbox(self):
        inputs = (ROOT / 'Trimato/HelpInputs.xcfilelist').read_text().splitlines()
        outputs = (ROOT / 'Trimato/HelpOutputs.xcfilelist').read_text().splitlines()
        for page in self.source.rglob('*.html'):
            relative = page.relative_to(self.source).as_posix()
            self.assertIn('$(SRCROOT)/Trimato/Trimato.help/' + relative, inputs)
            self.assertIn('$(DERIVED_FILE_DIR)/GeneratedHelp/Trimato.help/' + relative, outputs)

    def test_content_change_with_same_app_build_gets_distinct_book(self):
        first = self.generate()
        page = self.source / 'Contents/Resources/en.lproj/trim-silences.html'
        page.write_text(page.read_text().replace('Find and trim quiet pauses', 'Locate and trim quiet pauses'))
        second = self.generate()
        self.assertNotEqual(first['CFBundleIdentifier'], second['CFBundleIdentifier'])
        self.assertNotEqual(first['TrimatoHelpContentDigest'], second['TrimatoHelpContentDigest'])
        self.assertEqual(second['CFBundleShortVersionString'], '1.7.0')
        self.assertEqual(second['CFBundleVersion'], '3')
        builder.validate_indexes(self.output / 'Trimato.help', {'trimato-trim-silences': 'trim-silences.html'})

    def test_unchanged_content_reuses_validated_index(self):
        first = self.generate()
        index = self.output / 'Trimato.help/Contents/Resources/en.lproj/Trimato.cshelpindex'
        before = index.read_bytes()
        self.assertEqual(first, self.generate())
        self.assertEqual(before, index.read_bytes())

    def test_app_build_and_version_change_help_metadata(self):
        first = self.generate()
        second = self.generate(version='1.7.1', build='4')
        self.assertNotEqual(first['CFBundleIdentifier'], second['CFBundleIdentifier'])
        self.assertEqual(second['CFBundleShortVersionString'], '1.7.1')
        self.assertEqual(second['CFBundleVersion'], '4')

    def test_missing_anchor_fails_without_replacing_good_output(self):
        first = self.generate()
        page = self.source / 'Contents/Resources/en.lproj/trim-silences.html'
        page.write_text(page.read_text().replace('<a name="trimato-trim-silences"></a>', ''))
        with self.assertRaisesRegex(ValueError, 'missing contextual anchor'):
            self.generate()
        current = plistlib.loads((self.output / 'Trimato.help/Contents/Info.plist').read_bytes())
        self.assertEqual(first, current)

    def test_missing_page_fails(self):
        (self.source / 'Contents/Resources/en.lproj/trim-silences.html').unlink()
        with self.assertRaisesRegex(ValueError, 'missing contextual page'):
            self.generate()

    def test_stale_index_is_rejected(self):
        self.generate()
        index = self.output / 'Trimato.help/Contents/Resources/en.lproj/Trimato.cshelpindex'
        index.write_bytes(b'not a Help index')
        with self.assertRaisesRegex(ValueError, 'invalid Core Spotlight Help index'):
            self.generate()


if __name__ == '__main__':
    unittest.main()
