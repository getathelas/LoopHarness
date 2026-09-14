#!/usr/bin/env python3
"""Compile and run the real PDF pipeline on macOS or a booted iOS simulator.

Usage: python3 scripts/test_pdf_pagination.py [--simulator DEVICE_UDID]
Generated PDFs and a results.txt are retained in the test app's temporary folder.
"""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--simulator')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
os.environ.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
work = Path(tempfile.mkdtemp(prefix='loop-pdf-tests-'))
app = work / 'PDFPaginationTests.app'
resources = app if args.simulator else app / 'Contents/Resources'
binary = app / 'PDFPaginationTests' if args.simulator else app / 'Contents/MacOS/PDFPaginationTests'
resources.mkdir(parents=True)
binary.parent.mkdir(parents=True, exist_ok=True)
source = (root / 'LoopIOS/Structs/Messaging.swift').read_text()
start = source.index('struct PDFAttachment {')
end = source.index('\n}\n', start) + 3
model = work / 'PDFAttachment.swift'
model.write_text('import Foundation\n' + source[start:end])
for css in (root / 'LoopIOS/Skills/PDF/Templates').glob('*.css'):
    shutil.copy(css, resources)
sdk = 'iphonesimulator' if args.simulator else 'macosx'
sdk_path = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()
command = ['xcrun', '--sdk', sdk, 'swiftc', '-sdk', sdk_path, '-parse-as-library', '-o', str(binary)]
if args.simulator:
    command += ['-target', 'arm64-apple-ios18.0-simulator']
command += [str(model), str(root / 'LoopIOS/Skills/PDF/PDFGenerationService.swift'),
            str(root / 'LoopIOS/Skills/PDF/MarkdownToHTML.swift'),
            str(root / 'tests/pdf/PDFPaginationHarness.swift')]
subprocess.run(command, check=True)
info = {'CFBundleIdentifier': 'com.loop.pdf-pagination-tests', 'CFBundleExecutable': 'PDFPaginationTests',
        'CFBundleName': 'PDF Pagination Tests', 'CFBundlePackageType': 'APPL',
        'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0'}
if args.simulator:
    info.update({'MinimumOSVersion': '18.0', 'UIDeviceFamily': [1, 2], 'UILaunchScreen': {}})
info_path = app / 'Info.plist' if args.simulator else app / 'Contents/Info.plist'
info_path.write_bytes(plistlib.dumps(info))
if args.simulator:
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    subprocess.run(['xcrun', 'simctl', 'install', args.simulator, str(app)], check=True)
    subprocess.run(['xcrun', 'simctl', 'launch', '--console', args.simulator, info['CFBundleIdentifier']], check=True, timeout=180)
    container = subprocess.check_output(['xcrun', 'simctl', 'get_app_container', args.simulator, info['CFBundleIdentifier'], 'data'], text=True).strip()
    results = Path(container) / 'tmp/LoopPDFPaginationTests/results.txt'
    assert results.read_text().splitlines()[-1] == 'PASS', results.read_text()
else:
    subprocess.run([str(binary)], check=True, timeout=180)
