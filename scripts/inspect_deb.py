#!/usr/bin/env python3
"""Validate a built package without installing or extracting untrusted paths."""
import argparse
import hashlib
import io
import json
import plistlib
import subprocess
import tarfile
import tempfile
from pathlib import Path, PurePosixPath


def ar_members(data):
    if not data.startswith(b"!<arch>\n"):
        raise ValueError("Not a Debian ar archive")
    offset = 8
    members = {}
    while offset < len(data):
        header = data[offset:offset + 60]
        if len(header) != 60 or header[58:60] != b"`\n":
            raise ValueError("Invalid ar header")
        name = header[:16].decode("ascii").strip().rstrip("/")
        size = int(header[48:58].strip())
        start = offset + 60
        if size < 0 or start + size > len(data) or name in members:
            raise ValueError("Invalid ar member size or duplicate name")
        members[name] = data[start:start + size]
        offset = start + size + size % 2
    return members


def read_tar(members, prefix):
    candidates = [name for name in members if name.startswith(prefix + ".tar")]
    if len(candidates) != 1:
        raise ValueError(f"Expected one {prefix}.tar archive")
    return tarfile.open(fileobj=io.BytesIO(members[candidates[0]]), mode="r:*")


def file_map(archive):
    files = {}
    for member in archive.getmembers():
        name = PurePosixPath(member.name)
        if name.is_absolute() or ".." in name.parts:
            raise ValueError(f"Unsafe archive path: {member.name}")
        if member.isfile():
            normalized = str(name)
            if normalized in files:
                raise ValueError(f"Duplicate archive file: {normalized}")
            files[normalized] = member
    return files


def inspect(path, scheme, archs, macho=False):
    raw = path.read_bytes()
    members = ar_members(raw)
    if members.get("debian-binary") != b"2.0\n":
        raise ValueError("Missing Debian package version")
    with read_tar(members, "control") as control_tar:
        control_files = file_map(control_tar)
        control = control_tar.extractfile(control_files["control"]).read().decode("utf-8")
    fields = dict(line.split(": ", 1) for line in control.splitlines() if ": " in line)
    expected_arch = {"rootless":"iphoneos-arm64", "rootful":"iphoneos-arm", "roothide":"iphoneos-arm64e"}[scheme]
    if fields.get("Package") != "com.example.trafficmonitor" or fields.get("Architecture") != expected_arch:
        raise ValueError(f"Unexpected package identity/architecture: {fields}")
    prefix = "var/jb/" if scheme == "rootless" else ""
    library = prefix + "Library/MobileSubstrate/DynamicLibraries/TrafficMonitor"
    probe_path = prefix + "usr/libexec/trafficmonitor/tm-probe"
    with read_tar(members, "data") as data_tar:
        files = file_map(data_tar)
        if set(files) != {library + ".dylib", library + ".plist", probe_path}:
            raise ValueError(f"Unexpected stage-2 package payload: {sorted(files)}")
        actual_filter = plistlib.loads(data_tar.extractfile(files[library + ".plist"]).read())
        expected_filter = plistlib.loads((Path(__file__).resolve().parents[1] / "TrafficMonitor.plist").read_bytes())
        if actual_filter != expected_filter:
            raise ValueError("Packaged Filter differs from source")
        dylib = data_tar.extractfile(files[library + ".dylib"]).read()
        probe = data_tar.extractfile(files[probe_path]).read()
    report = {"file": path.name, "sha256": hashlib.sha256(raw).hexdigest(),
              "size_bytes": len(raw), "scheme": scheme, "control": fields,
              "files": sorted(files), "filter": actual_filter}
    if macho:
        with tempfile.TemporaryDirectory(prefix="trafficmonitor-macho-") as task_dir:
            binary = Path(task_dir) / "TrafficMonitor.dylib"
            binary.write_bytes(dylib)
            slices = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).strip()
            if set(slices.split()) != set(archs):
                raise ValueError(f"Unexpected Mach-O slices: {slices}")
            dependencies = subprocess.check_output(["otool", "-L", str(binary)], text=True)
            if scheme == "rootless" and any(line.strip().startswith(("/Library/", "/usr/lib/libsubstrate"))
                                            for line in dependencies.splitlines()[1:]):
                raise ValueError(f"Rootful library dependency in Rootless build: {dependencies}")
            report.update(macho_archs=slices, dependencies=dependencies,
                          load_commands=subprocess.check_output(["otool", "-l", str(binary)], text=True))
            probe_binary = Path(task_dir) / "tm-probe"
            probe_binary.write_bytes(probe)
            probe_slices = subprocess.check_output(["lipo", "-archs", str(probe_binary)], text=True).strip()
            if set(probe_slices.split()) != {"arm64"}:
                raise ValueError(f"Unexpected probe architecture: {probe_slices}")
            report.update(probe_archs=probe_slices)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("--scheme", choices=("rootless", "rootful", "roothide"), default="rootless")
    parser.add_argument("--archs", nargs="+", default=["arm64", "arm64e"])
    parser.add_argument("--macho", action="store_true", help="Also run macOS lipo/otool")
    args = parser.parse_args()
    print(json.dumps(inspect(args.package, args.scheme, args.archs, args.macho), indent=2))


if __name__ == "__main__":
    main()
