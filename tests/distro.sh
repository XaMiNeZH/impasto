#!/bin/bash
# Fedora install plans, with dnf and rpm replaced by stubs.
# Nothing is installed. A fake os-release selects the distro.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin" "$work/home" "$work/state" "$work/os" "$work/root"

cat > "$work/bin/dnf" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${IMPASTO_LOG:?}"
exit 0
EOF
cat > "$work/bin/timeout" <<'EOF'
#!/bin/bash
# Drop timeout's own flags so the stub PATH still reaches the dnf stub.
while [[ ${1:-} == -* ]]; do
    [[ $1 == -- ]] && { shift; break; }
    [[ $1 == --foreground ]] && { shift; continue; }
    shift
done
[[ ${1:-} =~ ^[0-9]+([.][0-9]+)?$ ]] && shift
exec "$@"
EOF
cat > "$work/bin/rpm" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${IMPASTO_LOG:?}"
# A Fedora machine that already has RPM Fusion ffmpeg and tuned-ppd.
if [[ ${1:-} == -q && ${2:-} == ffmpeg ]]; then exit 0; fi
if [[ ${1:-} == -q && ${2:-} == tuned-ppd ]]; then exit 0; fi
if [[ ${1:-} == -q && ${2:-} == --whatprovides && ${3:-} == ffmpeg-free ]]; then exit 0; fi
if [[ ${1:-} == -q && ${2:-} == --whatprovides && ${3:-} == ppd-service ]]; then exit 0; fi
exit 1
EOF
cat > "$work/bin/hyprland" <<'EOF'
#!/bin/bash
if [[ ${1:-} == --version && ${IMPASTO_HYPRLAND_VERSION:-} != none ]]; then
    printf 'Hyprland %s built from commit abc\n' "${IMPASTO_HYPRLAND_VERSION:-0.57.1}"
fi
exit 0
EOF
cat > "$work/bin/plymouth-set-default-theme" <<'EOF'
#!/bin/bash
printf 'bgrt\n'
exit 0
EOF
cat > "$work/bin/dracut" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod 755 "$work/bin/"*

cat > "$work/os/fedora" <<'EOF'
NAME="Fedora Linux"
ID=fedora
VERSION_ID=45
EOF
cat > "$work/os/debian" <<'EOF'
NAME="Debian GNU/Linux"
ID=debian
ID_LIKE=debian
EOF

theme="$work/root/usr/share/plymouth/themes/impasto"
mkdir -p "$theme" "$work/root/etc/dracut.conf.d"
printf 'theme\n' > "$theme/impasto.plymouth"
printf 'plymouth\n' > "$work/root/etc/dracut.conf.d/impasto.conf"

run_setup() {
    local release=$1
    shift
    IMPASTO_LOG=$work/log
    : > "$IMPASTO_LOG"
    env -u SUDO_ASKPASS \
        HOME="$work/home" \
        XDG_STATE_HOME="$work/state" \
        IMPASTO_OS_RELEASE="$work/os/$release" \
        IMPASTO_ROOT="$work/root" \
        IMPASTO_LOG="$IMPASTO_LOG" \
        IMPASTO_HYPRLAND_VERSION="${IMPASTO_HYPRLAND_VERSION:-}" \
        PATH="$work/bin:/usr/bin:/bin" \
        "$root/setup" "$@"
}

echo "fedora keeps hyprland 0.57.1 and plans dnf"
fedora_out=$(IMPASTO_HYPRLAND_VERSION=0.57.1 run_setup fedora packages --dry-run --noconfirm)
grep -q 'kept     hyprland 0.57.1' <<<"$fedora_out"
grep -q 'would install hyprland-devel-0.57.1 from sdegler/hyprland' <<<"$fedora_out"
if grep -q 'would install hyprland-0.57.1 ' <<<"$fedora_out"; then
    echo "fedora offered to replace an existing 0.57.1" >&2
    exit 1
fi
grep -q 'would build quickshell' <<<"$fedora_out"
grep -q 'would try COPR' <<<"$fedora_out"
if grep -E 'missing:.*ffmpeg-free|missing:.*power-profiles-daemon' <<<"$fedora_out"; then
    echo "fedora asked for packages already provided by ffmpeg or tuned-ppd" >&2
    exit 1
fi
if grep -q '── pacman' <<<"$fedora_out"; then
    echo "fedora took a pacman path" >&2
    exit 1
fi
if grep -E '(^| )install( |$)' "$work/log" | grep -q .; then
    echo "dry-run invoked dnf install" >&2
    cat "$work/log" >&2
    exit 1
fi
if grep -q 'for: hyprland ' <<<"$fedora_out" || grep -q 'for: hyprland$' <<<"$fedora_out"; then
    echo "a COPR line offered to replace the pinned hyprland" >&2
    exit 1
fi

echo "fedora leaves an older hyprland installed"
old_out=$(IMPASTO_HYPRLAND_VERSION=0.51.0 run_setup fedora packages --dry-run --noconfirm)
grep -q 'left     hyprland 0.51.0 — Impasto needs 0.57.1, and this one stays' <<<"$old_out"
if grep -q 'would install hyprland' <<<"$old_out"; then
    echo "fedora offered to replace an older hyprland" >&2
    exit 1
fi

echo "fedora installs 0.57.1 when hyprland is missing"
missing_out=$(IMPASTO_HYPRLAND_VERSION=none run_setup fedora packages --dry-run --noconfirm)
grep -q 'would install hyprland-0.57.1 hyprland-devel-0.57.1 from sdegler/hyprland' <<<"$missing_out"

echo "anything that is not Fedora is refused"
if run_setup debian packages --dry-run --noconfirm >"$work/debian.out" 2>"$work/debian.err"; then
    echo "debian was accepted" >&2
    exit 1
fi
grep -q 'impasto installs on Fedora' "$work/debian.err"

echo "fedora splash uses dracut"
splash_out=$(run_setup fedora splash --dry-run --noconfirm)
grep -q 'initramfs with dracut' <<<"$splash_out"
if grep -q 'mkinitcpio' <<<"$splash_out"; then
    echo "fedora splash mentioned mkinitcpio" >&2
    exit 1
fi

echo "fedora system files include the dracut drop-in"
system_out=$(run_setup fedora system --dry-run --noconfirm)
grep -q 'etc/dracut.conf.d/impasto.conf' <<<"$system_out"
if grep -q 'mkinitcpio' <<<"$system_out"; then
    echo "fedora deploy copied mkinitcpio" >&2
    exit 1
fi

echo "distro plans ok"
