#!/bin/bash
# Plans for Arch and Fedora, with the package tools replaced by stubs.
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
exit 1
EOF
cat > "$work/bin/pacman" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${IMPASTO_LOG:?}"
if [[ ${1:-} == -T ]]; then
    shift
    printf '%s\n' "$@"
fi
exit 0
EOF
cat > "$work/bin/hyprland" <<'EOF'
#!/bin/bash
if [[ ${1:-} == --version ]]; then
    printf 'Hyprland %s built from commit abc\n' "${IMPASTO_HYPRLAND_VERSION:-0.56.1}"
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
cat > "$work/bin/mkinitcpio" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod 755 "$work/bin/"*

cat > "$work/os/fedora" <<'EOF'
NAME="Fedora Linux"
ID=fedora
VERSION_ID=43
EOF
cat > "$work/os/arch" <<'EOF'
NAME="Arch Linux"
ID=arch
ID_LIKE=archlinux
EOF
cat > "$work/os/debian" <<'EOF'
NAME="Debian GNU/Linux"
ID=debian
ID_LIKE=debian
EOF

theme="$work/root/usr/share/plymouth/themes/impasto"
mkdir -p "$theme" "$work/root/etc/dracut.conf.d" "$work/root/etc/mkinitcpio.conf.d"
printf 'theme\n' > "$theme/impasto.plymouth"
printf 'plymouth\n' > "$work/root/etc/dracut.conf.d/impasto.conf"
printf 'plymouth\n' > "$work/root/etc/mkinitcpio.conf.d/impasto.conf"

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

echo "arch plans pacman"
arch_out=$(run_setup arch packages --dry-run --noconfirm)
grep -q 'pacman' <<<"$arch_out"
grep -q 'aur' <<<"$arch_out"
if grep -q 'fedora extras' <<<"$arch_out"; then
    echo "arch took the Fedora package path" >&2
    exit 1
fi
if grep -q '^install ' "$work/log"; then
    echo "dry-run invoked an installer" >&2
    exit 1
fi

echo "fedora plans dnf and keeps hyprland 0.56"
fedora_out=$(run_setup fedora packages --dry-run --noconfirm)
grep -q 'kept     hyprland 0.56.1' <<<"$fedora_out"
grep -q 'would build quickshell' <<<"$fedora_out"
grep -q 'would try COPR' <<<"$fedora_out"
if grep -q '── pacman' <<<"$fedora_out"; then
    echo "fedora took the pacman path" >&2
    exit 1
fi
if grep -E '(^| )install( |$)' "$work/log" | grep -q .; then
    echo "dry-run invoked dnf install" >&2
    cat "$work/log" >&2
    exit 1
fi
if grep -q 'for: hyprland ' <<<"$fedora_out" || grep -q 'for: hyprland$' <<<"$fedora_out"; then
    echo "fedora offered to replace a new enough hyprland" >&2
    exit 1
fi

echo "fedora leaves an older hyprland installed"
old_out=$(IMPASTO_HYPRLAND_VERSION=0.51.0 run_setup fedora packages --dry-run --noconfirm)
grep -q 'left     hyprland 0.51.0' <<<"$old_out"
if grep -q 'would install hyprland' <<<"$old_out"; then
    echo "fedora offered to replace an older hyprland" >&2
    exit 1
fi

echo "an unknown distro is refused"
if run_setup debian packages --dry-run --noconfirm >"$work/debian.out" 2>"$work/debian.err"; then
    echo "debian was accepted" >&2
    exit 1
fi
grep -q 'Arch Linux and Fedora' "$work/debian.err"

echo "fedora splash uses dracut"
splash_out=$(run_setup fedora splash --dry-run --noconfirm)
grep -q 'initramfs with dracut' <<<"$splash_out"
if grep -q 'mkinitcpio' <<<"$splash_out"; then
    echo "fedora splash mentioned mkinitcpio" >&2
    exit 1
fi

echo "fedora system files skip mkinitcpio"
system_out=$(run_setup fedora system --dry-run --noconfirm)
grep -q 'etc/dracut.conf.d/impasto.conf' <<<"$system_out"
if grep -q 'mkinitcpio' <<<"$system_out"; then
    echo "fedora deploy copied mkinitcpio" >&2
    exit 1
fi

echo "arch system files skip dracut"
arch_system=$(run_setup arch system --dry-run --noconfirm)
grep -q 'etc/mkinitcpio.conf.d/impasto.conf' <<<"$arch_system"
if grep -q 'dracut.conf' <<<"$arch_system"; then
    echo "arch deploy copied the dracut drop-in" >&2
    exit 1
fi

echo "distro plans ok"
