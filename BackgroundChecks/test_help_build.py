"""Run with PYTHONDONTWRITEBYTECODE=1 python3 BackgroundChecks/test_help_build.py."""
import importlib.util
from pathlib import Path
import plistlib
import re
import shutil
import tempfile
import unittest
import xml.etree.ElementTree as ET

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

    def test_menu_anchors_resolve_to_contents_and_quick_start(self):
        self.generate(version='1.9.2', build='3')
        book = self.output / 'Trimato.help'
        topics = builder.validate_pages(book)
        self.assertEqual(topics['trimato-help-contents'], 'index.html')
        self.assertEqual(topics['trimato-quickstart-guide'], 'quickstart.html')
        builder.validate_indexes(book, {
            'trimato-help-contents': 'index.html',
            'trimato-quickstart-guide': 'quickstart.html',
        })

    def test_missing_contents_anchor_fails_without_replacing_good_output(self):
        first = self.generate()
        landing = self.source / 'Contents/Resources/en.lproj/index.html'
        landing.write_text(landing.read_text().replace(
            '<a name="trimato-help-contents" id="trimato-help-contents"></a>', ''))
        with self.assertRaisesRegex(ValueError, 'missing contextual anchor trimato-help-contents'):
            self.generate()
        current = plistlib.loads((self.output / 'Trimato.help/Contents/Info.plist').read_bytes())
        self.assertEqual(first, current)

    def test_content_change_rebuilds_index_with_fresh_book_identity(self):
        first = self.generate()
        page = self.source / 'Contents/Resources/en.lproj/trim-silences.html'
        revision_page = page.with_name('revision-check.html')
        revision_page.write_text(page.read_text().replace('trimato-trim-silences', 'help-revision-check'))
        second = self.generate()
        self.assertNotEqual(first['CFBundleIdentifier'], second['CFBundleIdentifier'])
        self.assertNotEqual(first['TrimatoHelpContentDigest'], second['TrimatoHelpContentDigest'])
        self.assertEqual(first['CFBundleShortVersionString'], '2.0.0')
        self.assertEqual(first['CFBundleVersion'], '1')
        self.assertEqual(second['CFBundleShortVersionString'], first['CFBundleShortVersionString'])
        self.assertEqual(second['CFBundleVersion'], first['CFBundleVersion'])
        self.assertEqual(first['TrimatoHelpAppVersion'], second['TrimatoHelpAppVersion'])
        self.assertEqual(first['TrimatoHelpAppBuild'], second['TrimatoHelpAppBuild'])
        builder.validate_indexes(self.output / 'Trimato.help', {
            'trimato-trim-silences': 'trim-silences.html',
            'help-revision-check': 'revision-check.html',
        })

    def test_every_build_has_consistent_fresh_identity_with_app_build_two(self):
        identifiers = set()
        for _ in range(2):
            current = self.generate(version='1.9.1', build='2')
            identifier = current['CFBundleIdentifier']
            self.assertRegex(identifier, r'^com\.marconius\.trimato\.help\.build[0-9a-f]{32}$')
            self.assertNotIn(identifier, identifiers)
            identifiers.add(identifier)
            self.assertEqual(current['TrimatoHelpAppVersion'], '1.9.1')
            self.assertEqual(current['TrimatoHelpAppBuild'], '2')
            header = (self.output / 'TrimatoHelpInfo.h').read_text()
            self.assertEqual(header, f'#define TRIMATO_HELP_BOOK_IDENTIFIER {identifier}\n')
            landing = (self.output / 'Trimato.help/Contents/Resources/en.lproj/index.html').read_text()
            document = ET.fromstring(landing)
            namespace = '{http://www.w3.org/1999/xhtml}'
            self.assertIsNotNone(document.find(namespace + 'body/' + namespace + 'main'))
            self.assertEqual(document.find(namespace + 'head/' + namespace + 'meta[@name="AppleTitle"]').get('content'), identifier)
            builder.validate_indexes(self.output / 'Trimato.help', {
                'trimato-quickstart-guide': 'quickstart.html',
            })

    def test_app_build_and_version_change_help_metadata(self):
        first = self.generate(version='1.9.1', build='1')
        for version, build in [('1.9.1', '2'), ('1.9.2', '1')]:
            with self.subTest(version=version, build=build):
                current = self.generate(version=version, build=build)
                self.assertNotEqual(current['CFBundleIdentifier'], first['CFBundleIdentifier'])
                self.assertEqual(current['CFBundleShortVersionString'], first['CFBundleShortVersionString'])
                self.assertEqual(current['CFBundleVersion'], first['CFBundleVersion'])
                self.assertEqual(current['TrimatoHelpAppVersion'], version)
                self.assertEqual(current['TrimatoHelpAppBuild'], build)
                header = (self.output / 'TrimatoHelpInfo.h').read_text()
                self.assertEqual(header, f'#define TRIMATO_HELP_BOOK_IDENTIFIER {current["CFBundleIdentifier"]}\n')
                title = (self.output / 'Trimato.help/Contents/Resources/en.lproj/index.html').read_text()
                self.assertIn(f'<meta name="AppleTitle" content="{current["CFBundleIdentifier"]}" />', title)

    def test_malformed_landing_page_fails_without_replacing_good_output(self):
        first = self.generate()
        landing = self.source / 'Contents/Resources/en.lproj/index.html'
        landing.write_text(landing.read_text().replace(' />', '>'))
        with self.assertRaisesRegex(ValueError, 'not well-formed XHTML'):
            self.generate()
        current = plistlib.loads((self.output / 'Trimato.help/Contents/Info.plist').read_bytes())
        self.assertEqual(first, current)

    def test_missing_xhtml_namespace_is_rejected(self):
        landing = self.source / 'Contents/Resources/en.lproj/index.html'
        landing.write_text(landing.read_text().replace(' xmlns="http://www.w3.org/1999/xhtml"', ''))
        with self.assertRaisesRegex(ValueError, 'lacks the XHTML namespace'):
            self.generate()

    def test_missing_duplicate_and_mismatched_apple_titles_are_rejected(self):
        landing = self.source / 'Contents/Resources/en.lproj/index.html'
        original = landing.read_text()
        title = '<meta name="AppleTitle" content="com.marconius.trimato.help" />'
        for replacement in ['', title + title, title.replace('com.marconius.trimato.help', 'another.book')]:
            with self.subTest(replacement=replacement):
                landing.write_text(original.replace(title, replacement))
                with self.assertRaisesRegex(ValueError, 'AppleTitle does not match'):
                    self.generate()

    def test_app_placeholders_are_rejected_as_help_content_versions(self):
        metadata = self.source / 'Contents/Info.plist'
        info = plistlib.loads(metadata.read_bytes())
        for key, value in [('CFBundleShortVersionString', '$(MARKETING_VERSION)'),
                           ('CFBundleVersion', '$(CURRENT_PROJECT_VERSION)')]:
            with self.subTest(key=key):
                revised = dict(info, **{key: value})
                metadata.write_bytes(plistlib.dumps(revised))
                with self.assertRaisesRegex(ValueError, 'Help needs an explicit'):
                    self.generate()

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

    def test_stale_index_is_replaced_by_valid_fresh_index(self):
        first = self.generate()
        index = self.output / 'Trimato.help/Contents/Resources/en.lproj/Trimato.cshelpindex'
        index.write_bytes(b'not a Help index')
        second = self.generate()
        self.assertNotEqual(first['CFBundleIdentifier'], second['CFBundleIdentifier'])
        builder.validate_indexes(self.output / 'Trimato.help', {'trimato-quickstart-guide': 'quickstart.html'})


if __name__ == '__main__':
    unittest.main()
