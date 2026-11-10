#!/bin/bash
# Run on Fedora. Every required name in packages/dnf.txt must be visible to
# dnf. A line that starts with `?` is optional and may be absent.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
file=$root/packages/dnf.txt
missing=0

while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [[ -n $line ]] || continue
    optional=0
    if [[ $line == '?'* ]]; then
        optional=1
        line=${line#\?}
        line=${line#"${line%%[![:space:]]*}"}
    fi
    hit=$(dnf -q repoquery --available "$line" 2>/dev/null | head -1 || true)
    if [[ -n $hit ]]; then
        continue
    fi
    if (( optional )); then
        echo "optional missing: $line"
    else
        echo "REQUIRED missing: $line"
        missing=1
    fi
done < "$file"

if (( missing )); then
    echo "packages/dnf.txt names a package this Fedora does not have" >&2
    exit 1
fi
echo "required packages resolve"
