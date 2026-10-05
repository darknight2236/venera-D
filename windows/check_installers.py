"""Check windows/build.iss against an actual Windows build output.

Windows-on-ARM installers are not shipped (upstream venera reverted its arm64
support, and Flutter picks the Windows build architecture from the host CPU, so
an x64 CI runner cannot produce one). That leaves one installer script, and its
[Files] list is hand-maintained: sqlite3_flutter_libs_plugin.dll once stayed
behind after the plugin was removed, while the sqlite3 build hooks and
package:jni added native_assets.json and dartjni.dll without anyone noticing.
An installer missing a payload file only fails after a user runs it, so check it
against the build directory instead.

  python windows/check_installers.py --release-dir build/windows/x64/runner/Release
"""

import argparse
import fnmatch
import os
import re
import sys

ISS_PATH = "windows/build.iss"
ARCH = "x64"

# Build outputs that must never go into the installer. native_assets.json is the
# debug/JIT copy of the native-assets map; a release build has no such file next
# to the exe because the manifest ships inside data\flutter_assets and reaches
# the installer through the data\* entry.
IGNORED_OUTPUTS = ("*.pdb", "native_assets.json")

SOURCE_RE = re.compile(r'^Source:\s*"([^"]+)"', re.M)
DEFINE_RE = re.compile(r'^#define\s+(\w+)\s+"([^"]*)"', re.M)


def payload_names():
    """[Files] entries, relative to the runner output directory."""
    text = open(ISS_PATH, encoding="utf-8").read()
    defines = dict(DEFINE_RE.findall(text))
    prefix = re.compile(
        r"^\{#RootPath\}\\build\\windows\\" + ARCH + r"\\runner\\Release\\", re.I
    )
    names = []
    for source in SOURCE_RE.findall(text):
        rel = prefix.sub("", source)
        if rel == source:
            raise SystemExit(
                f"{ISS_PATH}: unexpected Source outside the {ARCH} runner output: "
                f"{source}"
            )
        # {#RootPath} is matched literally above, so expand the remaining
        # defines afterwards (MyAppExeName is the one naming a file).
        for name, value in defines.items():
            rel = rel.replace("{#" + name + "}", value)
        names.append(rel.lower())
    return names


def classify(names):
    exact, dirs, globs = set(), set(), set()
    for name in names:
        if name.endswith("\\*"):
            dirs.add(name[:-1])
        elif "*" in name:
            globs.add(name)
        else:
            exact.add(name)
    return exact, dirs, globs


def loose_files(release_dir):
    """Files the build dropped next to the executable."""
    out = []
    for entry in os.listdir(release_dir):
        if os.path.isdir(os.path.join(release_dir, entry)):
            # Directories reach the installer through data\* or are runtime
            # droppings; only loose files need an explicit entry.
            continue
        if not any(fnmatch.fnmatch(entry, g) for g in IGNORED_OUTPUTS):
            out.append(entry.lower())
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--release-dir",
        required=True,
        help="the built runner output directory to check the payload list against",
    )
    args = parser.parse_args()
    if not os.path.isdir(args.release_dir):
        raise SystemExit(f"no such directory: {args.release_dir}")

    exact, dirs, globs = classify(payload_names())
    problems = []

    missing = sorted(
        name for name in exact if not os.path.exists(os.path.join(args.release_dir, name))
    )
    if missing:
        problems.append(
            f"{ISS_PATH} lists files the build did not produce:\n"
            + "".join(f"  {n}\n" for n in missing)
        )

    unshipped = sorted(
        name
        for name in loose_files(args.release_dir)
        if name not in exact
        and not any(name.startswith(prefix) for prefix in dirs)
        and not any(fnmatch.fnmatch(name, glob) for glob in globs)
    )
    if unshipped:
        problems.append(
            "the build produced files the installer does not ship "
            "(add a Source line, or extend IGNORED_OUTPUTS if intended):\n"
            + "".join(f"  {n}\n" for n in unshipped)
        )

    if problems:
        print("::error::installer check failed")
        for problem in problems:
            print(problem)
        return 1

    print(
        f"installer check passed: {len(exact) + len(dirs) + len(globs)} payload "
        f"entries, every loose file in {args.release_dir} is accounted for"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
