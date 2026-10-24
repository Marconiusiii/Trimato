#!/usr/bin/python3
"""Generate and validate the Help bundle copied into an Xcode build."""
import argparse
import ctypes
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import uuid
import xml.etree.ElementTree as ET
from urllib.parse import unquote, urlsplit


class Page(HTMLParser):
    def __init__(self, text):
        super().__init__()
        self.anchors = set()
        self.links = []
        self.feed(text)

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if attrs.get('id'):
            self.anchors.add(attrs['id'])
        if tag == 'a' and attrs.get('name'):
            self.anchors.add(attrs['name'])
        if tag in ('a', 'link') and attrs.get('href'):
            self.links.append(attrs['href'])


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_pages(book):
    info = plistlib.loads((book / 'Contents/Info.plist').read_bytes())
    topics = plistlib.loads((book / 'Contents/Resources/HelpTopics.plist').read_bytes())
    require(bool(topics), 'No contextual Help destinations are declared.')
    topics.update({
        'trimato-help-contents': info['HPDBookAccessPath'],
        'trimato-quickstart-guide': 'quickstart.html',
    })
    for folder in sorted((book / 'Contents/Resources').glob('*.lproj')):
        landing = folder / info['HPDBookAccessPath']
        require(landing.is_file(), f'{folder.name}: missing Help landing page')
        try:
            document = ET.fromstring(landing.read_bytes())
        except ET.ParseError as error:
            raise ValueError(f'{folder.name}: Help landing page is not well-formed XHTML: {error}') from error
        namespace = '{http://www.w3.org/1999/xhtml}'
        require(document.tag == namespace + 'html', f'{folder.name}: Help landing page lacks the XHTML namespace')
        head = document.find(namespace + 'head')
        require(head is not None and document.find(namespace + 'body') is not None,
                f'{folder.name}: Help landing page needs head and body elements')
        titles = [meta for meta in head.findall(namespace + 'meta') if meta.get('name') == 'AppleTitle']
        require(len(titles) == 1 and titles[0].get('content') == info['CFBundleIdentifier'],
                f'{folder.name}: Help landing page AppleTitle does not match its book identifier')
        pages = {p.relative_to(folder).as_posix(): Page(p.read_text()) for p in folder.rglob('*.html')}
        require('index.html' in pages, f'{folder.name}: missing index.html')
        for anchor, name in topics.items():
            require(name in pages, f'{folder.name}: missing contextual page {name}')
            require(anchor in pages[name].anchors, f'{name}: missing contextual anchor {anchor}')
        for name, page in pages.items():
            for link in page.links:
                url = urlsplit(link)
                if url.scheme or url.netloc:
                    continue
                destination = ((folder / name).parent / unquote(url.path)).resolve() if url.path else (folder / name).resolve()
                require(destination.is_relative_to(book.resolve()), f'{name}: Help link escapes its bundle: {link}')
                require(destination.is_file(), f'{name}: missing Help link destination: {link}')
                if url.fragment and destination.suffix == '.html':
                    target = Page(destination.read_text())
                    require(unquote(url.fragment) in target.anchors, f'{name}: missing linked anchor: {link}')
    return topics


def index_records(path):
    source = path.read_bytes()
    decoder = ctypes.CDLL('/usr/lib/libcompression.dylib').compression_decode_buffer
    decoder.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_int]
    decoder.restype = ctypes.c_size_t
    output = ctypes.create_string_buffer(32 * 1024 * 1024)
    size = decoder(output, len(output), source, len(source), None, 0x801)
    require(size > 0, f'{path.name}: invalid Core Spotlight Help index')
    archive = plistlib.loads(output.raw[:size])
    require(archive.get('$archiver') == 'NSKeyedArchiver', f'{path.name}: unsupported Help index archive')
    return [item for item in archive.get('$objects', []) if isinstance(item, bytes)]


def validate_indexes(book, topics):
    info = plistlib.loads((book / 'Contents/Info.plist').read_bytes())
    for folder in sorted((book / 'Contents/Resources').glob('*.lproj')):
        records = index_records(folder / info['HPDBookIndexPath'])
        for anchor, page in topics.items():
            destination = f'/{page}#{anchor}'.encode()
            require(any(destination in record for record in records),
                    f'{folder.name}: index does not resolve {anchor} to {page}')


def generate(source, output, version, build, staging_directory=None):
    require(re.fullmatch(r'[0-9]+(?:\.[0-9]+)*', version), 'Invalid app version for Help generation')
    require(re.fullmatch(r'[0-9]+(?:\.[0-9]+)*', build), 'Invalid app build number for Help generation')
    source = source.resolve()
    output.mkdir(parents=True, exist_ok=True)
    topics = validate_pages(source)
    digest = hashlib.sha256()
    digest.update(Path(__file__).read_bytes())
    for path in sorted(source.rglob('*')):
        if path.is_file() and path.suffix not in ('.helpindex', '.cshelpindex') and path.name != '.DS_Store':
            digest.update(path.relative_to(source).as_posix().encode() + b'\0' + path.read_bytes())
    revision = digest.hexdigest()
    template = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    help_version = template['CFBundleShortVersionString']
    help_build = template['CFBundleVersion']
    require(isinstance(help_version, str) and re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', help_version),
            'Help needs an explicit three-part content version')
    require(isinstance(help_build, str) and re.fullmatch(r'[0-9]+(?:\.[0-9]+)*', help_build),
            'Help needs an explicit content build number')
    # A fresh identity prevents this build from resolving to a previously
    # registered Help book, even when the app version and content are unchanged.
    identifier = f"{template['CFBundleIdentifier']}.build{uuid.uuid4().hex}"
    expected = {'version': version, 'build': build, 'contentDigest': revision, 'bookIdentifier': identifier}
    book = output / 'Trimato.help'
    header = output / 'TrimatoHelpInfo.h'
    header_text = f'#define TRIMATO_HELP_BOOK_IDENTIFIER {identifier}\n'
    stamp = output / 'manifest.json'
    staging = staging_directory if staging_directory is not None else output / 'staging'
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir()
    try:
        staged_book = staging / 'Trimato.help'
        shutil.copytree(source, staged_book, ignore=shutil.ignore_patterns('*.helpindex', '*.cshelpindex', '.DS_Store'))
        info = dict(template, CFBundleIdentifier=identifier, TrimatoHelpAppVersion=version,
                    TrimatoHelpAppBuild=build, HPDBookIndexPath='Trimato.cshelpindex', TrimatoHelpContentDigest=revision)
        (staged_book / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        for folder in sorted((staged_book / 'Contents/Resources').glob('*.lproj')):
            landing = folder / info['HPDBookAccessPath']
            text = landing.read_text()
            old_title = f'<meta name="AppleTitle" content="{template["CFBundleIdentifier"]}" />'
            require(old_title in text, f'{folder.name}: Help landing page lacks its book identifier')
            landing.write_text(text.replace(old_title, f'<meta name="AppleTitle" content="{identifier}" />'))
            subprocess.run(['/usr/bin/hiutil', '-I', 'corespotlight', '-C', '-a', '-g', '-s', 'en',
                            '-l', folder.stem, '-f', str(folder / info['HPDBookIndexPath']), str(folder)], check=True)
        validate_pages(staged_book)
        validate_indexes(staged_book, topics)
        if book.exists():
            book.replace(staging / 'previous-help')
        staged_book.replace(book)
        (staging / 'header').write_text(header_text)
        (staging / 'header').replace(header)
        (staging / 'stamp').write_text(json.dumps(expected, sort_keys=True))
        (staging / 'stamp').replace(stamp)
        print(f'Generated and validated Help: {identifier}')
    finally:
        shutil.rmtree(staging)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    parser.add_argument('--staging', type=Path)
    args = parser.parse_args()
    try:
        generate(args.source, args.output, args.version, args.build, args.staging)
    except (ValueError, OSError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        print(f'error: Help generation failed: {error}', file=sys.stderr)
        sys.exit(1)
