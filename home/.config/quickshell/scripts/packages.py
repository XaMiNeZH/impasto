#!/usr/bin/env python3
# ╭──────────────────────────────────────────────────────────────────────────╮
# │                                                                          │
# │   P A C K A G E S                                                        │
# │   package queries · dnf and rpm, read only                               │
# │                                                                          │
# │   github.com/XaMiNeZH/impasto                                            │
# │                                                                          │
# ╰──────────────────────────────────────────────────────────────────────────╯

"""Read the rpm database and search the Fedora repositories.

    installed        every installed package, with its description, install
                     reason and whether it came from outside Fedora's own
                     repositories (a COPR, or a local build)
    search TERM      packages whose name contains TERM, ranked exact,
                     prefix, substring

Read-only: installing and upgrading run in a terminal, where dnf can ask
for a password and confirmation.
"""

import json
import os
import shutil
import subprocess
import sys

# Maximum rows returned by a search.
LISTED = 160

ENV = dict(os.environ, LANG="C", LC_ALL="C")

# Repositories that count as Fedora itself. Anything else installed
# (a COPR, a local build) is the foreign set the panel calls COPR.
FEDORA_REPOS = {
    "fedora", "updates", "updates-testing", "fedora-cisco-openh264",
    "anaconda", "@System",
}


def human_size(raw):
    """Bytes, as a size the panel can print: '1.50 MiB'."""
    try:
        size = float(raw)
    except (TypeError, ValueError):
        return raw or ""
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    index = 0
    while size >= 1024 and index < len(units) - 1:
        size /= 1024
        index += 1
    return f"{size:.2f} {units[index]}"


def run(command):
    try:
        return subprocess.run(command, capture_output=True, text=True,
                              timeout=60, env=ENV)
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"{command[0]} failed: {error}", file=sys.stderr)
        return None


def dnf_text(commands):
    """Stdout of the first command that exits 0, or None."""
    for command in commands:
        result = run(command)
        if result is not None and result.returncode == 0:
            return result.stdout
    return None


def dnf_userinstalled():
    text = dnf_text([
        ["dnf", "repoquery", "--userinstalled", "--format", "%{name}"],
        ["dnf", "repoquery", "--userinstalled", "--qf", "%{name}"],
    ])
    if text is None:
        return None
    return {line.strip() for line in text.splitlines() if line.strip() and " " not in line.strip()}


def dnf_foreign():
    text = dnf_text([
        ["dnf", "repoquery", "--installed", "--format", "%{name}\t%{repoid}"],
        ["dnf", "repoquery", "--installed", "--qf", "%{name}\t%{repoid}"],
    ])
    if text is None:
        return set()
    names = set()
    for line in text.splitlines():
        name, _, repo = line.strip().partition("\t")
        if not name or not repo or " " in name:
            continue
        base = repo.split(":", 1)[0]
        if base not in FEDORA_REPOS and not base.startswith("fedora"):
            names.add(name)
    return names


def parse_rpm_installed(text, explicit, foreign_names):
    """Rows for `rpm -qa --qf` with name, version, summary and size in bytes.

    `aur` is the foreign flag the panel already reads. On this desk it
    means COPR or a local build, not the Arch User Repository.
    """
    packages = []
    for line in text.splitlines():
        parts = line.split("\t")
        if len(parts) < 2 or not parts[0].strip():
            continue
        name = parts[0].strip()
        packages.append({
            "name": name,
            "version": parts[1].strip(),
            "description": parts[2].strip() if len(parts) > 2 else "",
            "size": human_size(parts[3].strip()) if len(parts) > 3 else "",
            "explicit": True if explicit is None else name in explicit,
            "aur": name in foreign_names,
        })
    return packages


def parse_dnf_search(text, term):
    """Rows from a repoquery format of name, evr and summary, filtered by name."""
    rows = []
    for line in text.splitlines():
        raw = line.strip()
        if not raw:
            continue
        if "\t" in raw:
            name, version, description = (raw.split("\t") + ["", ""])[:3]
        else:
            parts = raw.split()
            if len(parts) < 2:
                continue
            name, version, description = parts[0], parts[1], " ".join(parts[2:])
        name = name.strip()
        if not name or term not in name.lower():
            continue
        rows.append({
            "name": name,
            "version": version.strip(),
            "source": "fedora",
            "installed": False,
            "description": description.strip(),
        })
    return rows


def dnf_installed_names():
    result = run(["rpm", "-qa", "--qf", "%{NAME}\\n"])
    if result is None or result.returncode != 0:
        return set()
    return {line.strip() for line in result.stdout.splitlines() if line.strip()}


def installed():
    if not shutil.which("rpm"):
        print(json.dumps({"available": False, "manager": "dnf"}))
        return
    result = run(["rpm", "-qa", "--qf", "%{NAME}\\t%{VERSION}-%{RELEASE}\\t%{SUMMARY}\\t%{SIZE}\\n"])
    if result is None or result.returncode != 0:
        print(json.dumps({"available": False, "manager": "dnf"}))
        return
    explicit = dnf_userinstalled()
    print(json.dumps({
        "available": True,
        "manager": "dnf",
        "helper": "",
        "packages": parse_rpm_installed(result.stdout, explicit, dnf_foreign()),
    }))


def rank(name, term):
    """0 exact, 1 prefix, 2 anywhere in the name."""
    if name == term:
        return 0
    return 1 if name.startswith(term) else 2


def search(term):
    term = term.strip().lower()
    if len(term) < 2:
        print(json.dumps({"term": term, "results": [], "aur": "short", "manager": "dnf"}))
        return
    text = dnf_text([
        ["dnf", "repoquery", "--available", "--format", "%{name}\t%{evr}\t%{summary}", f"*{term}*"],
        ["dnf", "repoquery", "--available", "--qf", "%{name} %{evr} %{summary}", f"*{term}*"],
    ])
    if text is None:
        print("dnf did not answer", file=sys.stderr)
        print(json.dumps({
            "term": term, "results": [], "total": 0, "repos": 0,
            "aurCount": 0, "aur": "offline", "manager": "dnf",
        }))
        return
    mine = dnf_installed_names()
    rows = parse_dnf_search(text, term)
    for row in rows:
        row["installed"] = row["name"] in mine
    rows.sort(key=lambda row: (rank(row["name"], term), row["name"]))
    print(json.dumps({
        "term": term,
        "results": rows[:LISTED],
        "total": len(rows),
        "repos": len(rows),
        "aurCount": 0,
        "aur": "off",
        "manager": "dnf",
    }))


def main():
    verb = sys.argv[1] if len(sys.argv) > 1 else ""
    if verb == "installed":
        installed()
    elif verb == "search" and len(sys.argv) > 2:
        search(" ".join(sys.argv[2:]))
    else:
        print("usage: packages.py installed | search TERM", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
