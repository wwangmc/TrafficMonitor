#!/usr/bin/env python3
"""Bundle source, local dashboard and an inspected deb without user runtime data."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile
from inspect_deb import inspect

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('deb', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    report = inspect(args.deb, 'rootless', ['arm64', 'arm64e'])
    version = report['control']['Version']
    destination = args.output or ROOT / 'packages' / ('TrafficMonitor-' + version + '.zip')
    destination.parent.mkdir(parents=True, exist_ok=True)
    ignored = {'.git', '.theos', 'packages', '__pycache__', 'data', '.venv'}
    suffixes = {'.h','.xm','.mm','.c','.py','.md','.json','.plist','.yml','.yaml','.css','.js','.html','.ps1','.cmd','.txt'}
    names = {'Makefile','control','.gitignore','.gitattributes','LICENSE'}
    files = {}
    for path in ROOT.rglob('*'):
        relative = path.relative_to(ROOT)
        if not path.is_file() or any(part in ignored for part in relative.parts):
            continue
        if path.suffix not in suffixes and path.name not in names:
            continue
        if path.name == 'package-inspection.json':
            continue
        files[relative.as_posix()] = path.read_bytes()
    files['install/' + args.deb.name] = args.deb.read_bytes()
    manifest = {'version':version, 'deb_sha256':report['sha256'],
                'files':{name:hashlib.sha256(data).hexdigest() for name,data in files.items()}}
    files['MANIFEST.json'] = json.dumps(manifest, indent=2).encode()
    prefix = 'TrafficMonitor-' + version + '/'
    with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as archive:
        for name, data in sorted(files.items()):
            archive.writestr(prefix + name, data)
    with zipfile.ZipFile(destination) as archive:
        for name, digest in manifest['files'].items():
            if hashlib.sha256(archive.read(prefix + name)).hexdigest() != digest:
                raise ValueError('Bundle verification failed: ' + name)
    print(json.dumps({'file':str(destination),'files':len(files),'version':version,
                      'sha256':hashlib.sha256(destination.read_bytes()).hexdigest()}))


if __name__ == '__main__':
    main()
