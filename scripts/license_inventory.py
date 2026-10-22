#!/usr/bin/env python3
"""Lists every source file compiled into the libraries a build produced, and the licence of each.

Licences first: a library on Maven Central may carry only code whose licence lets it be
redistributed by a library, so the build fails on a licence it does not recognise as permissive,
and on any copyleft one, before anything is packaged. The answer comes from what the compiler was
actually given (ninja's command lines for the two targets), not from what the source tree contains.

For each compiled file the owner is the nearest directory above it, inside the ANGLE checkout,
that states a licence: a README.chromium's "License:" field (Chromium's convention for third-party
code), or else a LICENSE or COPYING file. ANGLE's own files fall to the LICENSE at its root.

    license_inventory.py <angle-checkout> <out-dir> <report.txt> <target>...

The report names each owner, its licence and how many of its files were compiled, followed by the
full text of every licence file involved; it travels in the platform's jar.
"""

import os
import re
import subprocess
import sys

PERMISSIVE = {
    "apache-2.0", "apache 2.0", "apache", "bsd-3-clause", "bsd-2-clause", "bsd", "mit", "zlib",
    "isc", "bsl-1.0", "boost", "unicode-3.0", "unicode-dfs-2016", "unicode", "khronos",
    "public domain", "unlicense", "cc0-1.0", "sgi-b-2.0", "x11", "ijg", "libpng", "ofl-1.1",
    "llvm exception", "apache-2.0 with llvm-exception",
}
COPYLEFT = re.compile(r"\b(a?gpl|lgpl|mpl|epl|cddl|eupl|osl|sspl)\b", re.IGNORECASE)
SOURCE = re.compile(r"(?:^|\s)(?:-c|/c|/Tp|/Tc)\s*(\S+\.(?:c|cc|cpp|cxx|m|mm))(?:\s|$)")
LICENCE_FILES = ("LICENSE", "LICENSE.txt", "LICENSE.md", "COPYING", "COPYING.txt", "NOTICE")


def ninja():
    """The ninja ANGLE's checkout carries: depot_tools' own is a script, a batch file on Windows."""
    for name in ("ninja.exe", "ninja"):
        candidate = os.path.join("third_party", "ninja", name)
        if os.path.isfile(candidate):
            return os.path.abspath(candidate)
    return "ninja"


def compiled_sources(out_dir, targets):
    commands = subprocess.run([ninja(), "-C", out_dir, "-t", "commands", *targets],
                              check=True, capture_output=True, text=True).stdout
    files = set()
    for line in commands.splitlines():
        for match in SOURCE.finditer(line):
            path = match.group(1).strip('"')
            files.add(os.path.normpath(os.path.join(out_dir, path)))
    return sorted(files)


def readme_licence(directory):
    readme = os.path.join(directory, "README.chromium")
    if not os.path.isfile(readme):
        return None
    licence, files = None, []
    with open(readme, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if line.lower().startswith("license:"):
                licence = line.split(":", 1)[1].strip()
            elif line.lower().startswith("license file:"):
                files = [f.strip() for f in line.split(":", 1)[1].split(",") if f.strip()]
    return (licence, files) if licence else None


def owner_of(root, path):
    directory = os.path.dirname(path)
    while True:
        if os.path.normpath(directory) == os.path.normpath(root):
            return root, "BSD-3-Clause (ANGLE)", [os.path.join(root, "LICENSE")]
        readme = readme_licence(directory)
        if readme:
            licence, files = readme
            paths = [os.path.normpath(os.path.join(directory, f.replace("//", root + "/", 1)
                                                   if f.startswith("//") else f)) for f in files]
            return directory, licence, [p for p in paths if os.path.isfile(p)]
        for name in LICENCE_FILES:
            candidate = os.path.join(directory, name)
            if os.path.isfile(candidate):
                return directory, classify(candidate), [candidate]
        parent = os.path.dirname(directory)
        if parent == directory:
            return directory, "UNKNOWN", []
        directory = parent


def classify(licence_file):
    with open(licence_file, encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    if COPYLEFT.search(text[:4000]) and "GNU" in text[:4000]:
        return "COPYLEFT? (" + os.path.basename(licence_file) + ")"
    if "Apache License" in text:
        return "Apache-2.0"
    if "Permission is hereby granted, free of charge" in text:
        return "MIT"
    if "Redistribution and use in source and binary forms" in text:
        return "BSD-3-Clause" if "Neither the name" in text or "endorse or promote" in text else "BSD-2-Clause"
    if "This software is provided 'as-is'" in text:
        return "Zlib"
    if "Boost Software License" in text:
        return "BSL-1.0"
    return "UNKNOWN (" + os.path.basename(licence_file) + ")"


def acceptable(licence):
    if COPYLEFT.search(licence) or licence.startswith("COPYLEFT") or licence.startswith("UNKNOWN"):
        return False
    parts = [p.strip().lower() for p in re.split(r",|/| or | and |;", licence) if p.strip()]
    return all(p in PERMISSIVE or p.split(" (")[0] in PERMISSIVE for p in parts)


def main():
    root, out_dir, report, *targets = sys.argv[1:]
    root = os.path.abspath(root)
    out_dir = os.path.abspath(out_dir)
    owners = {}
    for path in compiled_sources(out_dir, targets):
        if not path.startswith(root):
            continue  # generated into the out directory: ANGLE's own, from its scripts
        directory, licence, files = owner_of(root, path)
        entry = owners.setdefault(directory, {"licence": licence, "files": set(files), "count": 0})
        entry["count"] += 1
    refused = [(d, e["licence"]) for d, e in owners.items() if not acceptable(e["licence"])]
    with open(report, "w", encoding="utf-8") as out:
        out.write("Every source compiled into " + ", ".join(targets) + ", by the directory that\n")
        out.write("states its licence, with the number of files compiled from it.\n\n")
        for directory in sorted(owners):
            entry = owners[directory]
            name = os.path.relpath(directory, root)
            out.write(f"{'ANGLE' if name == '.' else name}: {entry['licence']} ({entry['count']} files)\n")
        texts = sorted({f for e in owners.values() for f in e["files"]})
        for path in texts:
            out.write("\n" + "=" * 78 + "\n" + os.path.relpath(path, root) + "\n" + "=" * 78 + "\n")
            with open(path, encoding="utf-8", errors="replace") as handle:
                out.write(handle.read())
    for directory in sorted(owners):
        print(f"  {os.path.relpath(directory, root)}: {owners[directory]['licence']} "
              f"({owners[directory]['count']} files)")
    if refused:
        for directory, licence in refused:
            print(f"REFUSED {os.path.relpath(directory, root)}: {licence}", file=sys.stderr)
        sys.exit("a compiled source carries a licence this payload may not redistribute, or one "
                 "this script does not recognise; read it, and add it to PERMISSIVE only if it is")


if __name__ == "__main__":
    main()
