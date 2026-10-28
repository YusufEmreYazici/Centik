#!/bin/bash
# Lists interface strings that have no English translation, and translations nothing uses.
# Keys are collected by the Swift compiler, so interpolated strings appear with their
# format specifiers (for example "%lld öğe"), exactly as they're looked up at run time.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
swift build --build-path "$WORK/build" -Xswiftc -emit-localized-strings \
    -Xswiftc -emit-localized-strings-path -Xswiftc "$WORK/strings" >/dev/null

python3 - "$WORK/strings" Resources/en.lproj <<'PY'
import glob, json, plistlib, re, sys
used = {}
for path in glob.glob(sys.argv[1] + "/*.stringsdata"):
    data = json.load(open(path))
    source = data["source"].rsplit("/", 1)[-1]
    if source in ("DemoRecorder.swift", "Snapshot.swift"):
        continue
    for items in data["tables"].values():
        for item in items:
            if item["key"].strip():
                used.setdefault(item["key"], f'{source}:{item["location"]["startingLine"]}')
pattern = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=', re.M)
unescape = lambda s: s.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")
english = {unescape(k) for k in pattern.findall(open(sys.argv[2] + "/Localizable.strings").read())}
english |= set(plistlib.load(open(sys.argv[2] + "/Localizable.stringsdict", "rb")))
missing = sorted(k for k in used if k not in english)
unused = sorted(k for k in english if k not in used)
for k in missing:
    print(f"missing  {used[k]}  {k!r}")
for k in unused:
    print(f"unused   {k!r}")
print(f"{len(used)} strings, {len(missing)} missing, {len(unused)} unused")
sys.exit(1 if missing else 0)
PY
