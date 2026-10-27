#!/usr/bin/env python3
"""Static project validation only. This does not compile or validate injection."""
import argparse
import json
import os
import plistlib
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def check(require_yaml=False):
    failures = []

    def require(condition, message):
        if not condition:
            failures.append(message)

    required = ("Makefile", "control", "Tweak.xm", "TrafficMonitor.plist",
                "Sources/TMTarget.h", ".github/workflows/build.yml", "README.md",
                "docs/IMPLEMENTATION_PLAN.md", "docs/PROGRESS.md",
                "docs/COMPATIBILITY.md", "docs/DEVICE_VALIDATION.md")
    for name in required:
        require((ROOT / name).is_file(), f"Missing {name}")
    if failures:
        return failures

    source_suffixes = {".h", ".xm", ".mm", ".py", ".md", ".yml", ".plist"}
    for path in ROOT.rglob("*"):
        relative = path.relative_to(ROOT)
        if any(part in {".git", ".theos", "packages", "__pycache__"}
               for part in relative.parts):
            continue
        if not path.is_file() or not (path.suffix in source_suffixes or path.name in {
                "Makefile", "control", ".gitignore", ".gitattributes"}):
            continue
        data = path.read_bytes()
        require(not data.startswith(b"\xef\xbb\xbf"), f"UTF-8 BOM: {relative}")
        require(b"\r" not in data, f"Expected LF: {relative}")
        text = data.decode("utf-8")
        require(re.search(r"@@[A-Z_]+@@", text) is None,
                f"Unexpanded generator token: {relative}")

    plist = plistlib.loads((ROOT / "TrafficMonitor.plist").read_bytes())
    bundles = plist.get("Filter", {}).get("Bundles", [])
    require(set(plist) == {"Filter"} and set(plist["Filter"]) == {"Bundles"},
            "Only an exact Bundle Filter is allowed")
    require(len(bundles) == 1 and isinstance(bundles[0], str), "Expected one Bundle ID")
    header = (ROOT / "Sources/TMTarget.h").read_text(encoding="utf-8")
    match = re.search(r'#define TM_TARGET_BUNDLE_ID @"([^"\n]+)"', header)
    require(match is not None and bundles == [match.group(1)],
            "Filter and runtime Bundle ID disagree")
    if bundles:
        require(re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundles[0]) is not None,
                "Invalid Bundle ID")

    makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
    for value in ("TYPE ?= 1", "iphone:clang:$(TM_SDK):15.0",
                  "iphone:clang:$(TM_SDK):14.0", "THEOS_PACKAGE_SCHEME = rootless",
                  "TrafficMonitor_FILES = Tweak.xm", "-DTM_ROOTLESS=$(TM_ROOTLESS)"):
        require(value in makefile, f"Missing build setting: {value}")
    require("INSTALL_TARGET_PROCESSES =" not in makefile, "No guessed process kill allowed")
    for name in ("Sources/TMHTTP.h", "Sources/TMHTTPMonitor.mm", "Sources/TMHTTPRecorder.mm",
                 "probe/Makefile", "probe/main.mm", "probe/TMFixture.mm"):
        require((ROOT / name).is_file(), f"Missing stage-2 source: {name}")
    control = dict(line.split(": ", 1) for line in
                   (ROOT / "control").read_text(encoding="utf-8").splitlines() if ": " in line)
    for key in ("Package", "Name", "Version", "Architecture", "Description", "Maintainer", "Depends"):
        require(bool(control.get(key)), f"Missing control field: {key}")
    require(control.get("Architecture") == "iphoneos-arm", "Let Theos set final package architecture")

    try:
        import yaml
    except ImportError:
        require(not require_yaml, "PyYAML missing; install PyYAML to check workflow syntax")
        print("SKIP: YAML parsing (install PyYAML or use --require-yaml to require it)")
    else:
        # BaseLoader keeps GitHub's YAML `on` key as a string (not YAML 1.1 bool).
        workflow = yaml.load((ROOT / ".github/workflows/build.yml").read_text(encoding="utf-8"),
                             Loader=yaml.BaseLoader)
        require(workflow.get("permissions") == {"contents": "read"}, "Expected read-only CI permissions")
        require(set(workflow.get("on", {})) == {"push", "pull_request", "workflow_dispatch"},
                "Missing CI triggers")
        matrix = workflow["jobs"]["build"]["strategy"]["matrix"]["include"]
        require(matrix == [{"mode":"rootful","type":"0","archs":"arm64"},
                           {"mode":"rootless","type":"1","archs":"arm64 arm64e"},
                           {"mode":"roothide","type":"2","archs":"arm64 arm64e"}],
                "CI should build the three independent package schemes")
    return failures


def environment():
    theos = os.environ.get("THEOS")
    return {
        "platform": sys.platform,
        "python": sys.version.split()[0],
        "tools": {tool: shutil.which(tool) for tool in
                  ("git", "make", "gmake", "clang", "perl", "dpkg-deb", "xcodebuild", "wsl")},
        "THEOS": theos,
        "theos_common_mk_exists": bool(theos and (Path(theos) / "makefiles/common.mk").is_file()),
        "sdk_16_5_exists": bool(theos and (Path(theos) / "sdks/iPhoneOS16.5.sdk/SDKSettings.plist").is_file()),
        "note": "Tool presence does not imply a working iOS toolchain or a successful build."
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--require-yaml", action="store_true")
    parser.add_argument("--environment", action="store_true")
    args = parser.parse_args()
    if args.environment:
        print(json.dumps(environment(), indent=2))
    try:
        failures = check(args.require_yaml)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        failures = [f"Invalid project metadata: {exc}"]
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    if failures:
        return 1
    print("PASS: static metadata, target consistency, encoding and build settings")
    print("NOT CHECKED BY THIS SCRIPT: iOS compilation, .deb contents, installation or injection")
    return 0


if __name__ == "__main__":
    sys.exit(main())
