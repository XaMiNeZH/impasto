#!/usr/bin/env python3
# ╭──────────────────────────────────────────────────────────────────────────╮
# │                                                                          │
# │   U P D A T E S                                                          │
# │   packages an upgrade would touch · counted, never installed             │
# │                                                                          │
# │   github.com/XaMiNeZH/impasto                                            │
# │                                                                          │
# ╰──────────────────────────────────────────────────────────────────────────╯

"""List pending updates from the Fedora repositories, read-only.

`dnf check-upgrade` answers. Exit 100 means updates are available. Upgrades
run in a terminal, never from here. With no dnf the result is unavailable
and the module is hidden.
"""

import json
import os
import subprocess
import sys

# How many names ride along for the module's one line; the panel reads the
# whole list from `updates`.
LISTED = 15

ENV = dict(os.environ, LANG="C", LC_ALL="C")


def run(command, timeout=120):
    try:
        return subprocess.run(command, capture_output=True, text=True,
                              timeout=timeout, env=ENV)
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"{command[0]} failed: {error}", file=sys.stderr)
        return None


def parse_dnf(text):
    """Rows from `dnf check-upgrade`.

    dnf4 prints `name.arch  new-evr  repo`. dnf5 also prints
    `name  old -> new`. A header line is ignored.
    """
    rows = []
    for line in text.splitlines():
        raw = line.strip()
        if not raw or raw.endswith(":") or raw.lower().startswith("last metadata"):
            continue
        if " -> " in raw:
            parts = raw.split()
            if len(parts) >= 4 and parts[2] == "->":
                rows.append({"name": parts[0], "from": parts[1], "to": parts[3], "source": "repo"})
            continue
        parts = raw.split()
        if len(parts) < 2:
            continue
        name = parts[0]
        if "." in name:
            name = name.rsplit(".", 1)[0]
        if name.lower() in {"package", "updating", "obsoleting"}:
            continue
        rows.append({"name": name, "from": "", "to": parts[1], "source": "repo"})
    return rows


def main():
    result = run(["dnf", "check-upgrade"])
    # 100 is dnf for "updates are available", which is an answer.
    if result is None or result.returncode not in (0, 100):
        print("dnf check-upgrade did not answer", file=sys.stderr)
        print(json.dumps({"available": False, "manager": "dnf"}))
        return
    rows = parse_dnf(result.stdout)
    print(json.dumps({
        "available": True,
        "manager": "dnf",
        "tool": "dnf",
        "aur": False,
        "count": len(rows),
        "packages": [row["name"] for row in rows[:LISTED]],
        "updates": rows,
    }))


if __name__ == "__main__":
    main()
