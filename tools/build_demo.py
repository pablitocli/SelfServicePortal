#!/usr/bin/env python3
"""Build the static online demo of the portal (no server, sample data, nothing executes).

Output: demo/dist/ - deploy it to any static host (Netlify, GitHub Pages, S3...).
The demo reuses the real web UI (web/assets) and answers /api/* in the browser
with demo/src/demo-mock.js. Usage: python3 tools/build_demo.py [output_dir]
"""
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / 'demo' / 'src'
WEB = ROOT / 'web'
OUT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'demo' / 'dist'

# The two places where the real UI talks to the server outside /api/*
PATCHES = {
    'app.js': [
        ("const f = document.createElement('form'); f.method = 'post'; f.action = '/logout'; document.body.appendChild(f); f.submit();",
         "window.labSignOut && window.labSignOut();"),
        ('<a href="/api/requests/${encodeURIComponent(r.id)}/reports/${encodeURIComponent(f.name)}" target="_blank" rel="noopener">',
         '<a href="#" data-lab-report="${esc(f.name)}">'),
    ],
}


def version():
    m = re.search(r'^## \[(\d+\.\d+\.\d+)\]', (ROOT / 'CHANGELOG.md').read_text(encoding='utf-8'), re.M)
    return m.group(1) if m else 'dev'


def main():
    if OUT.exists():
        shutil.rmtree(OUT)
    (OUT / 'assets').mkdir(parents=True)

    for name in ('app.js', 'admin.js', 'branding.js'):
        text = (WEB / 'assets' / name).read_text(encoding='utf-8')
        for old, new in PATCHES.get(name, []):
            if text.count(old) != 1:
                sys.exit(f'build_demo: patch target not found exactly once in web/assets/{name}: {old[:60]}...')
            text = text.replace(old, new)
        (OUT / 'assets' / name).write_text(text, encoding='utf-8')
    shutil.copy(WEB / 'assets' / 'vendor' / 'qrcode.js', OUT / 'assets' / 'qrcode.js')
    shutil.copy(SRC / 'demo-mock.js', OUT / 'assets' / 'demo-mock.js')
    shutil.copytree(SRC / 'data', OUT / 'data')
    shutil.copytree(SRC / 'reports', OUT / 'reports')
    shutil.copy(SRC / 'robots.txt', OUT / 'robots.txt')

    index = (WEB / 'index.html').read_text(encoding='utf-8')
    body = index[index.index('<body>') + len('<body>'):index.index('<script')].strip()
    css = (WEB / 'assets' / 'portal.css').read_text(encoding='utf-8')
    page = (SRC / 'index.template.html').read_text(encoding='utf-8')
    page = page.replace('/*@PORTAL_CSS@*/', css).replace('<!--@PORTAL_BODY@-->', body).replace('@VERSION@', version())
    (OUT / 'index.html').write_text(page, encoding='utf-8')
    print(f'Demo built in {OUT} (version {version()})')


if __name__ == '__main__':
    main()
