#!/usr/bin/env python3
# ╭──────────────────────────────────────────────────────────────────────────╮
# │                                                                          │
# │   P A C K A G E S                                                        │
# │   package queries · pacman and the aur, read only                        │
# │                                                                          │
# │   github.com/andreumassanet/impasto                                      │
# │                                                                          │
# ╰──────────────────────────────────────────────────────────────────────────╯

"""Read the package database and search the repositories and the AUR.

    installed        every installed package, with its description, install
                     reason and whether it is foreign, plus the AUR helper
    search TERM      packages whose name contains TERM, from the sync
                     databases and the AUR, ranked exact, prefix, substring

Read-only: installing and upgrading run in a terminal, where pacman can ask
for a password and confirmation. The AUR is searched over its RPC; a term the
RPC rejects as too broad is retried as a prefix through `suggest`. Offline,
the AUR part is null and the repositories still answer.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import threading
import urllib.parse
import urllib.request

AUR_RPC = "https://aur.archlinux.org/rpc/v5"
AUR_TIMEOUT = 8

# Maximum rows returned by a search.
LISTED = 160

# Supported AUR helpers, in order of preference. `setup` builds yay-bin when
# neither is installed.
HELPERS = ("yay", "paru")

ENV = dict(os.environ, LANG="C", LC_ALL="C")

# Repositories that count as the distribution itself. Anything else installed
# on Fedora (a COPR, a local build) is the foreign set the panel calls "aur".
FEDORA_REPOS = {
    "fedora", "updates", "updates-testing", "fedora-cisco-openh264",
    "anaconda", "@System",
}


def family():
    """arch, fedora, or "" when os-release does not say."""
    path = os.environ.get("IMPASTO_OS_RELEASE", "/etc/os-release")
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError:
        return ""
    ident = like = ""
    for line in text.splitlines():
        key, _, value = line.partition("=")
        value = value.strip().strip('"')
        if key == "ID":
            ident = value
        elif key == "ID_LIKE":
            like = value
    if ident in {"arch", "artix", "manjaro", "endeavouros", "cachyos"} or "arch" in like.split():
        return "arch"
    if ident == "fedora" or "fedora" in like.split():
        return "fedora"
    return ""


def manager():
    """Which package database this machine answers with."""
    distro = family()
    if distro == "fedora" or (distro != "arch" and shutil.which("dnf") and not shutil.which("pacman")):
        return "dnf"
    if shutil.which("pacman") or distro == "arch":
        return "pacman"
    return ""


def human_size(raw):
    """Bytes, as pacman writes a size: '1.50 MiB'."""
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
    """Rows for `rpm -qa --qf` with name, version, summary and size in bytes."""
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


def run(command):
    try:
        return subprocess.run(command, capture_output=True, text=True,
                              timeout=60, env=ENV)
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"{command[0]} failed: {error}", file=sys.stderr)
        return None


def helper():
    return next((name for name in HELPERS if shutil.which(name)), "")


def foreign():
    """Names installed from outside the sync databases — the AUR, mostly."""
    result = run(["pacman", "-Qqm"])
    if result is None or result.returncode not in (0, 1):
        return set()
    return set(result.stdout.split())


# ── INSTALLED ───────────────────────────────────────────────────────────────


def dnf_installed():
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


def installed():
    if manager() == "dnf":
        dnf_installed()
        return
    result = run(["pacman", "-Qi"])
    if result is None or result.returncode != 0:
        print(json.dumps({"available": False}))
        return

    aur = foreign()
    packages = []
    entry = {}
    field = ""
    for line in result.stdout.splitlines() + [""]:
        if not line.strip():
            if entry.get("Name"):
                packages.append({
                    "name": entry["Name"],
                    "version": entry.get("Version", ""),
                    "description": entry.get("Description", ""),
                    "size": entry.get("Installed Size", ""),
                    "explicit": entry.get("Install Reason", "").startswith("Explicitly"),
                    "aur": entry["Name"] in aur,
                })
            entry = {}
            field = ""
            continue
        if line.startswith(" ") and field:
            # A value that wraps continues on an indented line.
            entry[field] = f"{entry[field]} {line.strip()}"
            continue
        key, _, value = line.partition(":")
        field = key.strip()
        entry[field] = value.strip()

    print(json.dumps({
        "available": True,
        "manager": "pacman",
        "helper": helper(),
        "packages": packages,
    }))


# ── SEARCH ──────────────────────────────────────────────────────────────────


def rank(name, term):
    """0 exact, 1 prefix, 2 anywhere in the name."""
    if name == term:
        return 0
    return 1 if name.startswith(term) else 2


def repositories(term, into):
    # `pacman -Ss` takes a regular expression and also matches descriptions,
    # so the term is escaped and the results are filtered by name here.
    result = run(["pacman", "-Ss", "--", re.escape(term)])
    found = []
    if result is not None and result.returncode == 0:
        head = None
        for line in result.stdout.splitlines():
            if not line.startswith(" "):
                # extra/firefox 142.0-1 (group) [installed: 141.0-1]
                parts = line.split(" ")
                repo, _, name = parts[0].partition("/")
                head = {
                    "name": name,
                    "version": parts[1] if len(parts) > 1 else "",
                    "source": repo,
                    "installed": "[installed" in line,
                    "description": "",
                }
                found.append(head)
            elif head is not None:
                head["description"] = line.strip()
    into["repos"] = [row for row in found if term in row["name"].lower()]


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "impasto"})
    with urllib.request.urlopen(request, timeout=AUR_TIMEOUT) as response:
        return json.load(response)


def aur(term, into):
    quoted = urllib.parse.quote(term, safe="")
    try:
        answer = fetch(f"{AUR_RPC}/search/{quoted}?by=name")
        prefix = False
        if answer.get("type") == "error":
            # Too many results: ask for the names that START with it, which
            # the RPC answers in order, and then for their details.
            names = fetch(f"{AUR_RPC}/suggest/{quoted}")
            prefix = True
            if not names:
                into["aur"] = []
                into["aurNote"] = "prefix"
                return
            query = urllib.parse.urlencode([("arg[]", name) for name in names])
            answer = fetch(f"{AUR_RPC}/info?{query}")
    except (OSError, ValueError) as error:
        print(f"The AUR did not answer: {error}", file=sys.stderr)
        into["aur"] = None
        return

    mine = foreign()
    into["aur"] = [{
        "name": row.get("Name", ""),
        "version": row.get("Version", ""),
        "source": "aur",
        "installed": row.get("Name", "") in mine,
        "description": row.get("Description") or "",
        "votes": row.get("NumVotes", 0),
        "popularity": row.get("Popularity", 0),
        "outOfDate": row.get("OutOfDate") is not None,
    } for row in answer.get("results", [])]
    into["aurNote"] = "prefix" if prefix else ""


def dnf_installed_names():
    result = run(["rpm", "-qa", "--qf", "%{NAME}\\n"])
    if result is None or result.returncode != 0:
        return set()
    return {line.strip() for line in result.stdout.splitlines() if line.strip()}


def search_dnf(term):
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


def search(term):
    if manager() == "dnf":
        search_dnf(term)
        return
    term = term.strip().lower()
    if len(term) < 2:
        # The RPC rejects single-character terms.
        print(json.dumps({"term": term, "results": [], "aur": "short"}))
        return

    found = {}
    threads = [threading.Thread(target=repositories, args=(term, found)),
               threading.Thread(target=aur, args=(term, found))]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    repos = found.get("repos", [])
    remote = found.get("aur")
    # A name in both is the repository's: that is the one pacman installs.
    taken = {row["name"] for row in repos}
    remote_rows = [row for row in (remote or []) if row["name"] not in taken]

    # Match quality first, whichever the source, so `hyprland` ranks above
    # repository packages that merely contain it. Within a tier the
    # repositories lead, and AUR results follow by popularity.
    rows = sorted(repos + remote_rows, key=lambda row: (
        rank(row["name"], term),
        row["source"] == "aur",
        -row.get("popularity", 0),
        row["name"],
    ))

    print(json.dumps({
        "term": term,
        "results": rows[:LISTED],
        "total": len(rows),
        "repos": len(repos),
        "aurCount": len(remote_rows),
        "aur": "offline" if remote is None else (found.get("aurNote") or "ok"),
        "manager": "pacman",
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
