# Fedora half of ./setup. Sourced by setup; not run on its own.
# Arch keeps packages/pacman.txt and packages/aur.txt. This file is what
# runs when /etc/os-release says fedora.

DISTRO=unknown
DISTRO_ID=
DISTRO_VERSION=
OS_RELEASE=${IMPASTO_OS_RELEASE:-/etc/os-release}
HYPRLAND_KEEP=0

read_distro() {
    DISTRO=unknown
    DISTRO_ID=
    DISTRO_VERSION=
    [[ -f $OS_RELEASE ]] || return 0
    local key value id= like= version=
    while IFS='=' read -r key value || [[ -n $key ]]; do
        [[ $key == '#'* || -z $key ]] && continue
        value=${value%\"}
        value=${value#\"}
        value=${value%$'\r'}
        case $key in
            ID) id=$value ;;
            ID_LIKE) like=$value ;;
            VERSION_ID) version=$value ;;
        esac
    done < "$OS_RELEASE"
    DISTRO_ID=$id
    DISTRO_VERSION=$version
    case $id in
        arch|artix|manjaro|endeavouros|cachyos|archlinux) DISTRO=arch ;;
        fedora) DISTRO=fedora ;;
        *)
            case " $like " in
                *' arch '*|*' archlinux '*) DISTRO=arch ;;
                *' fedora '*) DISTRO=fedora ;;
            esac
            ;;
    esac
}

# $1 is a path relative to system/. True when this distro must not copy it.
distro_skips() {
    case ${DISTRO:-unknown} in
        fedora)
            [[ $1 == etc/mkinitcpio.conf.d/* || $1 == etc/default/grub.d/* ]]
            ;;
        *)
            [[ $1 == etc/dracut.conf.d/* ]]
            ;;
    esac
}

desk_line() {
    if [[ $DISTRO == fedora ]]; then printf 'a desk for Fedora and Hyprland'
    else printf 'a desk for Arch Linux and Hyprland'; fi
}

# One name a line. $2 is required, optional or all. A leading `?` marks
# an optional name; `#` comments are dropped first.
manifest_names() {
    local file=$1 which=${2:-all} line mark
    [[ -f $file ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%%#*}
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        [[ -n $line ]] || continue
        mark=required
        if [[ $line == '?'* ]]; then
            mark=optional
            line=${line#\?}
            line=${line#"${line%%[![:space:]]*}"}
        fi
        [[ -n $line ]] || continue
        [[ $which == all || $which == "$mark" ]] || continue
        printf '%s\n' "$line"
    done < "$file"
}

# $1 installed, $2 minimum. Equal counts as new enough. Non-numeric tails
# (fc43, git snapshots) are ignored after the dotted numbers.
version_at_least() {
    local IFS=.
    local -a got want
    read -ra got <<< "${1%%[^0-9.]*}"
    read -ra want <<< "${2%%[^0-9.]*}"
    local i n=${#got[@]} x y
    (( ${#want[@]} > n )) && n=${#want[@]}
    for (( i = 0; i < n; i++ )); do
        x=${got[i]:-0}
        y=${want[i]:-0}
        x=${x//[^0-9]/}
        y=${y//[^0-9]/}
        [[ -n $x ]] || x=0
        [[ -n $y ]] || y=0
        if (( 10#$x > 10#$y )); then return 0; fi
        if (( 10#$x < 10#$y )); then return 1; fi
    done
    return 0
}

hyprland_version() {
    local line=
    if command -v hyprland >/dev/null; then
        line=$(hyprland --version 2>/dev/null | head -1) || true
    elif command -v hyprctl >/dev/null; then
        line=$(hyprctl version 2>/dev/null | head -1) || true
    fi
    [[ $line =~ ([0-9]+\.[0-9]+([.][0-9]+)?) ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}

quickshell_version() {
    local bin line=
    for bin in qs quickshell; do
        command -v "$bin" >/dev/null || continue
        line=$("$bin" --version 2>&1 | head -1) || true
        [[ $line =~ ([0-9]+\.[0-9]+([.][0-9]+)?) ]] || continue
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    done
    return 1
}

dnf_has() {
    command -v rpm >/dev/null || return 1
    rpm -q "$1" >/dev/null 2>&1
}

# dnf with the keyboard closed, so a GPG or metadata prompt cannot hang
# with nothing on the screen. A timeout beats a lock held by GNOME Software.
dnf_cmd() {
    if command -v timeout >/dev/null; then
        timeout --foreground 90 dnf "$@" </dev/null
    else
        dnf "$@" </dev/null
    fi
}

# Prefer the cache so a dry run and the extras pass do not wait on the
# network. Fall back to a refresh when the cache cannot answer.
dnf_repoquery() {
    dnf_cmd --cacheonly -q repoquery --available "$@" 2>/dev/null \
        || dnf_cmd -C -q repoquery --available "$@" 2>/dev/null \
        || dnf_cmd -q repoquery --available "$@" 2>/dev/null \
        || true
}

dnf_first_line() {
    local text=$1
    text=${text%%$'\n'*}
    printf '%s' "$text"
}

# True when a repository that is already enabled can see this name.
dnf_available() {
    local out
    out=$(dnf_first_line "$(dnf_repoquery "$1")")
    [[ -n $out ]]
}

dnf_pkg_version() {
    local out
    out=$(dnf_first_line "$(dnf_repoquery --format '%{version}' "$1")")
    if [[ -z $out || $out == *'%'* ]]; then
        out=$(dnf_first_line "$(dnf_repoquery --qf '%{version}' "$1")")
    fi
    [[ $out == *'%'* ]] && out=
    printf '%s' "$out"
}

# Names among "$@" that a repository currently offers, one per line.
dnf_which_available() {
    local out name
    (( $# )) || return 0
    out=$(dnf_repoquery --format '%{name}' "$@")
    if [[ -z $out || $out == *'%'* ]]; then
        out=$(dnf_repoquery --qf '%{name}' "$@")
    fi
    [[ $out == *'%'* ]] && out=
    [[ -n $out ]] || return 0
    printf '%s\n' "$out" | awk 'NF && $0 !~ /%/' | sort -u
}

# Names ./setup installs itself, so the optional pass does not race them.
fedora_special() {
    case $1 in
        hyprland|hyprland-devel|hyprpm|quickshell|awww|swww) return 0 ;;
    esac
    return 1
}

copr_id() {
    # dnf repolist prints copr:copr.fedorainfracloud.org:owner:project
    printf 'copr:copr.fedorainfracloud.org:%s' "${1//\//:}"
}

copr_enabled() {
    dnf repolist --enabled 2>/dev/null | grep -qF "$(copr_id "$1")"
}

# True when installing these names would replace qt6-qtbase with an older
# build. COPRs that link Qt's private API do this and take the desk down.
copr_downgrades_qt() {
    local out
    out=$(sudo dnf install -y --assumeno "$@" 2>&1 || true)
    grep -qi 'qt6-qtbase' <<<"$out" && grep -qiE 'downgrad' <<<"$out"
}

copr_can_install() {
    local out
    out=$(sudo dnf install -y --assumeno "$1" 2>&1 || true)
    grep -qiE 'No match for|nothing provides|Problem:|conflicting requests|Could not depsolve' <<<"$out" && return 1
    grep -qiE 'Installing:|Upgrading:|is already installed|Package .* is already' <<<"$out"
}

verb_packages_fedora() {
    command -v dnf >/dev/null || fail 'dnf is not installed'
    local -a want missing optional installable
    local name ver

    section dnf
    mapfile -t want < <(manifest_names "$REPO/packages/dnf.txt" required)
    missing=()
    for name in "${want[@]}"; do
        dnf_has "$name" || missing+=("$name")
    done
    if (( ${#missing[@]} )); then
        say "missing: ${missing[*]}"
        act sudo dnf install -y --skip-unavailable "${missing[@]}" \
            || fail 'dnf could not install the Fedora packages'
    else
        say "all ${#want[@]} installed"
    fi

    section 'fedora extras'
    say 'checking optional packages'
    mapfile -t optional < <(manifest_names "$REPO/packages/dnf.txt" optional)
    local -a check=()
    installable=()
    for name in "${optional[@]}"; do
        fedora_special "$name" && continue
        dnf_has "$name" && continue
        check+=("$name")
    done
    if (( ${#check[@]} )); then
        if (( DRY )); then
            say "would look for: ${check[*]}"
        else
            mapfile -t installable < <(dnf_which_available "${check[@]}")
        fi
    fi
    if (( ${#installable[@]} )); then
        say "missing: ${installable[*]}"
        act sudo dnf install -y --skip-unavailable "${installable[@]}" \
            || say 'skipped  some optional packages were not installable'
    elif (( DRY && ${#check[@]} )); then
        :
    elif (( ! ${#optional[@]} )); then
        say 'nothing optional listed'
    else
        say 'nothing more in the Fedora repositories'
    fi

    fedora_hyprland
    fedora_copr
    fedora_hyprland_after
    fedora_quickshell
    fedora_wallpaper
    fedora_starship
    fedora_nerd_font
    fedora_note_apps
    fedora_still_missing
}

fedora_hyprland() {
    local ver
    ver=$(hyprland_version || true)
    if [[ -n $ver ]]; then
        HYPRLAND_KEEP=1
        if version_at_least "$ver" 0.56; then
            say "kept     hyprland $ver"
        else
            say "left     hyprland $ver — Impasto needs 0.56 or newer, and this one stays"
        fi
        return 0
    fi
    say 'checking whether the repositories have hyprland 0.56'
    ver=$(dnf_pkg_version hyprland || true)
    if [[ -n $ver ]] && version_at_least "$ver" 0.56; then
        if (( DRY )); then
            say "would install hyprland $ver"
            return 0
        fi
        if sudo dnf install -y hyprland; then
            HYPRLAND_KEEP=1
            say "installed hyprland $ver"
        fi
    fi
}

fedora_hyprland_after() {
    local ver
    (( HYPRLAND_KEEP )) && return 0
    ver=$(hyprland_version || true)
    if [[ -z $ver ]]; then
        say 'skipped  hyprland — no Fedora build of 0.56 or newer could be installed without downgrading Qt'
        return 0
    fi
    if version_at_least "$ver" 0.56; then
        HYPRLAND_KEEP=1
        say "installed hyprland $ver"
    else
        HYPRLAND_KEEP=1
        say "left     hyprland $ver — Impasto needs 0.56 or newer, and this one stays"
    fi
}

fedora_copr() {
    local line repo pkg pkgs_rest
    local -a pkgs need
    local enabled_here installed_here
    [[ -f $REPO/packages/copr.txt ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%%#*}
        line=${line#"${line%%[![:space:]]*}"}
        [[ -n $line ]] || continue
        read -r repo pkgs_rest <<< "$line"
        read -ra pkgs <<< "$pkgs_rest"
        need=()
        for pkg in "${pkgs[@]}"; do
            [[ $pkg == hyprland && $HYPRLAND_KEEP == 1 ]] && continue
            dnf_has "$pkg" && continue
            command -v "$pkg" >/dev/null && continue
            need+=("$pkg")
        done
        (( ${#need[@]} )) || continue
        if (( DRY )); then
            say "would try COPR $repo for: ${need[*]}"
            continue
        fi
        enabled_here=0
        installed_here=0
        if ! copr_enabled "$repo"; then
            if ! sudo dnf copr enable -y "$repo"; then
                say "skipped  COPR $repo could not be enabled"
                continue
            fi
            enabled_here=1
        fi
        for pkg in "${need[@]}"; do
            if copr_downgrades_qt "$pkg"; then
                say "skipped  $pkg from $repo — it would downgrade Qt"
                continue
            fi
            if ! copr_can_install "$pkg"; then
                continue
            fi
            if sudo dnf install -y "$pkg"; then
                say "installed $pkg from $repo"
                installed_here=1
            else
                say "skipped  $pkg from $repo did not install"
            fi
        done
        if (( enabled_here && ! installed_here )); then
            sudo dnf copr disable -y "$repo" >/dev/null 2>&1 || true
            say "disabled $repo — nothing from it was installed"
        fi
    done < "$REPO/packages/copr.txt"
}

fedora_quickshell() {
    local ver tag src
    ver=$(quickshell_version || true)
    if [[ -n $ver ]] && version_at_least "$ver" 0.3; then
        say "kept     quickshell $ver"
        return 0
    fi
    say 'checking whether the repositories have quickshell 0.3'
    ver=$(dnf_pkg_version quickshell || true)
    if [[ -n $ver ]] && version_at_least "$ver" 0.3; then
        if (( DRY )); then
            say "would install quickshell $ver"
            return 0
        fi
        if sudo dnf install -y quickshell; then
            say "installed quickshell $ver"
        fi
        return 0
    fi
    ver=$(quickshell_version || true)
    if [[ -n $ver ]]; then
        say "quickshell $ver is older than 0.3 — building 0.3 against this system's Qt"
    else
        say 'quickshell is not installed — building 0.3 against this system'"'"'s Qt'
    fi
    if (( DRY )); then
        say 'would build quickshell from source into /usr/local'
        return 0
    fi
    local -a deps=(cmake ninja-build gcc-c++ git qt6-qtbase-devel qt6-qtdeclarative-devel
        qt6-qtwayland-devel qt6-qtsvg-devel wayland-devel wayland-protocols-devel
        mesa-libGL-devel jemalloc-devel libunwind-devel pam-devel pkgconf)
    sudo dnf install -y "${deps[@]}" || {
        say 'skipped  quickshell build dependencies are not available'
        return 0
    }
    tag=$(git ls-remote --tags https://github.com/quickshell-mirror/quickshell 'v0.3*' \
        | awk -F/ '{print $NF}' | sed 's/\^{}//' | sort -uV | tail -1)
    [[ -n $tag ]] || tag=v0.3.0
    src=$STATE/src/quickshell
    rm -rf "$src"
    if ! git clone -q --depth=1 --branch "$tag" https://github.com/quickshell-mirror/quickshell "$src"; then
        say 'skipped  quickshell could not be cloned'
        return 0
    fi
    if cmake -S "$src" -B "$src/build" -G Ninja \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX=/usr/local \
            -DVENDOR_CPPTRACE=ON \
        && cmake --build "$src/build" \
        && sudo cmake --install "$src/build"; then
        say "built    quickshell $tag"
    else
        say 'skipped  quickshell did not build — the desk needs qs 0.3 or newer'
    fi
}

fedora_wallpaper() {
    local dest
    if command -v awww >/dev/null && command -v awww-daemon >/dev/null; then
        say 'kept     awww'
        return 0
    fi
    if ! command -v swww >/dev/null; then
        say 'skipped  no awww or swww — the wallpaper stays on the last still image'
        return 0
    fi
    if (( DRY )); then
        say 'would install awww wrappers for swww'
        return 0
    fi
    dest=/usr/local/bin
    sudo install -m 755 "$REPO/lib/awww" "$dest/awww"
    sudo install -m 755 "$REPO/lib/awww-daemon" "$dest/awww-daemon"
    say 'installed awww wrappers for swww'
}

fedora_nerd_font() {
    if command -v fc-list >/dev/null && fc-list : family 2>/dev/null | grep -qi 'JetBrainsMono Nerd Font'; then
        say 'kept     JetBrainsMono Nerd Font'
        return 0
    fi
    if (( DRY )); then
        say 'would install JetBrainsMono Nerd Font'
        return 0
    fi
    command -v curl >/dev/null || { say 'skipped  JetBrainsMono Nerd Font — curl is not installed'; return 0; }
    local dest=${XDG_DATA_HOME:-$HOME/.local/share}/fonts/JetBrainsMonoNerd tag url
    mkdir -p "$dest"
    for tag in v3.4.0 v3.3.0 v3.2.1; do
        url="https://github.com/ryanoasis/nerd-fonts/releases/download/${tag}/JetBrainsMono.tar.xz"
        if curl -fsSL -o "$dest/font.tar.xz" "$url" \
            && tar -xJf "$dest/font.tar.xz" -C "$dest"; then
            rm -f "$dest/font.tar.xz"
            command -v fc-cache >/dev/null && fc-cache -f "$dest" >/dev/null 2>&1 || true
            say "installed JetBrainsMono Nerd Font $tag"
            return 0
        fi
        rm -f "$dest/font.tar.xz"
    done
    say 'skipped  JetBrainsMono Nerd Font could not be downloaded'
}

fedora_starship() {
    command -v starship >/dev/null && { say 'kept     starship'; return 0; }
    if (( DRY )); then
        say 'would install starship from its upstream installer, if no package provides it'
        return 0
    fi
    command -v curl >/dev/null || { say 'skipped  starship — curl is not installed'; return 0; }
    if curl -fsSL https://starship.rs/install.sh | sh -s -- -y; then
        say 'installed starship'
    else
        say 'skipped  starship — not in the Fedora repositories'
    fi
}

fedora_still_missing() {
    (( DRY )) && return 0
    local name
    for name in hyprpicker hyprsunset satty yazi; do
        command -v "$name" >/dev/null || say "skipped  $name — not installed"
    done
}

fedora_note_apps() {
    command -v codium >/dev/null || say 'skipped  VSCodium — install the upstream rpm, then ./setup vscodium'
    if ! command -v zen >/dev/null && ! command -v zen-browser >/dev/null; then
        say 'skipped  Zen — not in the Fedora repositories'
    fi
    command -v vesktop >/dev/null || say 'skipped  Vesktop — not in the Fedora repositories'
    if ! command -v spotify >/dev/null; then
        say 'skipped  Spotify — a Flatpak build is not themed by ./setup spotify'
    elif ! command -v spicetify >/dev/null; then
        say 'skipped  spicetify — not in the Fedora repositories'
    fi
    command -v quickemu >/dev/null || say 'skipped  quickemu — not in the Fedora repositories'
}

fedora_plugin_deps() {
    [[ $DISTRO == fedora ]] || return 0
    command -v dnf >/dev/null || return 0
    local -a need=() name
    for name in cmake meson gcc-c++ cpio pkgconf; do
        dnf_has "$name" || need+=("$name")
    done
    if ! dnf_has hyprland-devel && dnf_available hyprland-devel; then
        need+=(hyprland-devel)
    fi
    (( ${#need[@]} )) || return 0
    say "missing: ${need[*]}"
    if (( DRY )); then return 0; fi
    sudo dnf install -y "${need[@]}" || say 'skipped  some plugin build packages were not installed'
}

fedora_i2c_group() {
    [[ $DISTRO == fedora ]] || return 0
    [[ -z ${ROOT:-} ]] || return 0
    getent group i2c >/dev/null 2>&1 || return 0
    if id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx i2c; then return 0; fi
    if act ${SUDO:-sudo} usermod -aG i2c "$USER"; then
        say "added    $USER to the i2c group — external monitor brightness applies at the next login"
    else
        say 'skipped  could not add this user to the i2c group'
    fi
}

fedora_selinux() {
    [[ $DISTRO == fedora ]] || return 0
    command -v restorecon >/dev/null || return 0
    local mode base
    mode=$(getenforce 2>/dev/null || true)
    [[ $mode == Enforcing || $mode == Permissive ]] || return 0
    if (( DRY )); then
        say 'would label the system files for SELinux'
        return 0
    fi
    base=${ROOT:-/}
    if ${SUDO:-} restorecon -R \
        "$base/usr/lib/impasto" \
        "$base/usr/share/sddm/themes/impasto" \
        "$base/usr/share/plymouth/themes/impasto" \
        "$base/usr/share/polkit-1/actions" \
        "$base/etc/pam.d/impasto-face" >/dev/null 2>&1; then
        say 'labeled  the system files for SELinux'
    else
        say 'skipped  restorecon could not label the system files'
    fi
}

# The virtual camera is opt-in. v4l2loopback is not in Fedora's own
# repositories; the verb says so instead of calling pacman.
fedora_install_camera() {
    local -a pkgs=(python3-numpy python3-opencv kernel-devel)
    dnf_available akmod-v4l2loopback && pkgs+=(akmod-v4l2loopback)
    dnf_available kmod-v4l2loopback && pkgs+=(kmod-v4l2loopback)
    act sudo dnf install -y "${pkgs[@]}" || return 1
    if (( DRY )); then return 0; fi
    if ! dnf_has akmod-v4l2loopback && ! dnf_has kmod-v4l2loopback; then
        return 1
    fi
    if ! python3 -c 'import mediapipe' 2>/dev/null; then
        if dnf_available python3-mediapipe; then
            sudo dnf install -y python3-mediapipe || return 1
        elif command -v pip3 >/dev/null || python3 -m pip --version >/dev/null 2>&1; then
            python3 -m pip install --user mediapipe || return 1
        else
            return 1
        fi
    fi
    return 0
}

verb_splash_fedora() {
    local base=${ROOT:-/}
    section 'boot splash'
    if [[ -n $ROOT ]] && (( ! DRY )); then
        refuse 'the boot splash is set up on the machine itself, not in a chroot' || return
    fi
    command -v plymouth-set-default-theme >/dev/null || refuse 'plymouth is not installed (package: plymouth)' || return
    command -v dracut >/dev/null || refuse 'the initramfs is not built by dracut' || return
    [[ -f $base/usr/share/plymouth/themes/impasto/impasto.plymouth && -f $base/etc/dracut.conf.d/impasto.conf ]] \
        || refuse 'the theme is not installed (./setup system)' || return
    if (( DRY )); then
        say 'would choose the theme, add splash to the kernel command line and rebuild the initramfs with dracut'
        return 0
    fi
    sudo -v
    if [[ $(plymouth-set-default-theme) != impasto ]]; then
        sudo plymouth-set-default-theme impasto || refuse 'the theme could not be chosen' || return
    fi
    say 'theme    impasto'
    if command -v grubby >/dev/null; then
        sudo grubby --update-kernel=ALL --args=splash \
            || say 'skipped  grubby could not add splash'
    fi
    sudo dracut -f >/dev/null || refuse 'the initramfs did not rebuild' || return
    say 'rebuilt  the initramfs, with plymouth'
    command -v restorecon >/dev/null && sudo restorecon -R /usr/share/plymouth/themes/impasto >/dev/null 2>&1 || true
    stamp splash
    say 'ok · from the next boot'
}

fedora_uninstall_splash() {
    act sudo dracut -f >/dev/null || say 'the initramfs did not rebuild: sudo dracut -f'
    if command -v grubby >/dev/null; then
        act sudo grubby --update-kernel=ALL --remove-args=splash >/dev/null 2>&1 || true
    fi
}
