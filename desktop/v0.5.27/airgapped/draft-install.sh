#!/usr/bin/env bash
# Cosmonic Desktop — air-gapped tarball installer (Linux).
#
# TARGET: a machine with no internet and a user with no administrative rights.
# Everything this script does by default is unprivileged and writes only under
# $HOME. It never calls sudo on its own. Where a step genuinely cannot be done
# without root, it does not attempt it — it prints a copy-pasteable block to
# hand to whoever does have root, and continues.
#
# WHAT THIS DOES AND DOES NOT DO
# ------------------------------
# This tree is electron-builder's `linux-unpacked` payload. Unlike the .deb and
# .rpm targets it carries no maintainer scripts, so nothing registers the app
# with the desktop and nothing puts it on PATH. That is the gap this fills:
#
#   * a PATH entry            -> $BINDIR/cosmonic-desktop  (symlink to the
#                                sandbox-aware cosmonic-desktop.sh wrapper)
#   * a desktop entry + icon  -> so it appears in the launcher, and so the
#                                app's own `cosmonic://` protocol handler
#                                registration has a .desktop file to land in
#   * the GNOME tray extension (per-user; GNOME hides legacy tray icons)
#   * a readiness report      -> the things that DO need root or distro media
#                                (shared libraries, Chromium's sandbox, a C
#                                linker), named precisely enough to escalate
#
# It deliberately does NOT touch the air-gap payload. resources/go-mirror.tar,
# rust-mirror.tar and toolchain-bundle.tar are unpacked by `cosmonicd` itself
# (crates/cosmonicd/src/preflight.rs), which finds them via COSMONIC_RESOURCES
# and seeds them on the first toolchain install — offline, and still signature-
# verified for the OCI bundle. Unpacking them here by hand would only duplicate
# ~530 MB and confuse the daemon's seed markers. Same for the bundled `cosmonic`
# CLI: preflight symlinks it onto PATH and records an ownership marker.
#
# The app is registered IN PLACE. Nothing is copied except a ~40 KB icon and a
# few text files, so this stays cheap; the flip side is that moving this
# directory breaks the install — move it, then re-run this script.
#
# Usage:
#   ./install.sh                     unprivileged install into ~/.local
#   ./install.sh --autostart         ...and start Cosmonic Desktop on login
#   ./install.sh --check             report readiness only, change nothing
#   ./install.sh --admin-notes       print just the block to send to an admin
#   ./install.sh --uninstall         remove everything this script created
#   ./install.sh --dry-run           print the actions, change nothing
#
#   ./install.sh --prefix=/usr/local system-wide (needs root; not the air-gap
#                                    default, but supported if you have it)
#   ./install.sh --sandbox=apparmor  configure Chromium's sandbox via sudo
#   ./install.sh --sandbox=suid      ...via the setuid helper instead
#                                    (both need root — for admin-run installs)

set -euo pipefail

SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
HERE="$(cd -- "$(dirname -- "$SELF")" && pwd)"

APP_ID="cosmonic-desktop"

# Read from the package rather than hardcoded: this script ships inside the
# tarball and would otherwise advertise a stale version the moment it is
# carried into the next release. Empty is fine — the help just omits it.
app_version() {
  local meta v
  meta="$HERE/resources/gnome-shell-extension/cosmonic-tray@cosmonic.com/metadata.json"
  [ -f "$meta" ] || meta="$HERE/resources/gnome-shell-extension-legacy/cosmonic-tray@cosmonic.com/metadata.json"
  if [ -f "$meta" ]; then
    v="$(sed -n 's/.*"version-name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$meta" | head -1)"
    [ -n "$v" ] && { printf '%s' "$v"; return; }
  fi
  # Fall back to the directory name, e.g. cosmonic-desktop-0.5.27-x64-airgap.
  printf '%s' "$(basename -- "$HERE" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
}
APP_VERSION="$(app_version)"
APP_NAME="Cosmonic Desktop"
BIN="$HERE/$APP_ID"
LAUNCHER="$HERE/$APP_ID.sh"
SANDBOX_BIN="$HERE/chrome-sandbox"
RESOURCES="$HERE/resources"
EXT_UUID="cosmonic-tray@cosmonic.com"

PREFIX="${PREFIX:-$HOME/.local}"
SANDBOX_MODE="report"     # never escalates on its own; see --sandbox
DO_AUTOSTART=0
DO_EXTENSION=auto
UNINSTALL=0
DRY_RUN=0
CHECK_ONLY=0
ADMIN_NOTES_ONLY=0
FORCE=0

# Collected as we go, printed at the end. These are exactly the items a user
# without root cannot resolve alone.
declare -a ADMIN_ITEMS=()
need_admin() { ADMIN_ITEMS+=("$1"); }

# Things that stop the app from running at all, as opposed to things that merely
# need root. --check reports every one it finds rather than exiting at the first,
# because a report that stops halfway is worse than no report.
declare -a BLOCKERS=()
blocker() { BLOCKERS+=("$1"); }

# ---------------------------------------------------------------- helpers ---

is_tty() { [ -t 1 ]; }
if is_tty && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; N=$'\033[0m'
else
  B=''; DIM=''; RED=''; YEL=''; GRN=''; N=''
fi

say()  { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '  %s+%s %s\n' "$GRN" "$N" "$*"; }
skip() { printf '  %s-%s %s\n' "$DIM" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$YEL" "$N" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$RED" "$N" "$*" >&2; exit 1; }

# Every mutation goes through run() so --dry-run and --check are honest rather
# than best-effort: there is no second code path that could drift from the real
# one.
run() {
  if [ "$DRY_RUN" = 1 ] || [ "$CHECK_ONLY" = 1 ]; then
    printf '  %s$ %s%s\n' "$DIM" "$*" "$N"
    return 0
  fi
  "$@"
}

write_file() { # write_file <path>, content on stdin
  local path="$1" content
  content="$(cat)"
  if [ "$DRY_RUN" = 1 ] || [ "$CHECK_ONLY" = 1 ]; then
    printf '  %s$ write %s (%d bytes)%s\n' "$DIM" "$path" "${#content}" "$N"
    return 0
  fi
  mkdir -p -- "$(dirname -- "$path")"
  printf '%s\n' "$content" > "$path"
}

# Purpose-written rather than scraped from the header comment above: that block
# explains the package internals to whoever maintains this script, which is not
# what someone trying to install the app needs to read.
usage() {
  local d="${PREFIX:-$HOME/.local}"
  cat <<EOF
${B}Cosmonic Desktop${APP_VERSION:+ $APP_VERSION} — air-gapped installer${N}

Installs $APP_NAME on a machine with ${B}no internet access${N}, for a user with
${B}no administrator rights${N}. Everything below is unprivileged and writes only
under your home directory; this script never calls sudo on its own.

${B}USAGE${N}
  ./install.sh [options]

${B}GETTING STARTED${N}
  ./install.sh --check          See if this machine is ready. Changes nothing.
  ./install.sh                  Install.
  $APP_ID              Launch (or use your application menu).

  Then, in the app: accept the EULA, open ${B}Doctor${N} and choose
  ${B}Install toolchain${N}. That unpacks the bundled Rust, Go and wasm tools
  from resources/ — offline, no root, still signature-verified.

${B}OPTIONS${N}
  --check             Report readiness and exit. Checks architecture, shared
                      libraries, free space, sandbox and C linker. Exits
                      non-zero if something would stop the app from running.
  --admin-notes       Print the steps that need root, with this machine's real
                      paths filled in, ready to forward to an administrator.
  --autostart         Also start $APP_NAME on login (into the tray).
  --extension         Install the GNOME tray extension even if this does not
                      look like a GNOME session.
  --no-extension      Never install it.
  --uninstall         Remove everything this script created. Leaves your
                      projects and settings alone.
  --dry-run, -n       Print every action without performing it.
  --help, -h          This text.

${B}OPTIONS YOU PROBABLY DO NOT NEED${N}
  --prefix=DIR        Install location. Default: $d
                      Anything outside your home directory needs root.
  --sandbox=apparmor  Configure Chromium's sandbox via sudo, by AppArmor
                      profile (preferred) or the setuid helper. Only for
  --sandbox=suid      installs run BY an administrator — if that is not you,
                      use --admin-notes instead.
  --sandbox=none      Stay silent about the sandbox.
  --force, -f         Install even if the architecture does not match. The app
                      will not start; only useful for staging a deployment.

${B}ENVIRONMENT${N}
  PREFIX                    Same as --prefix.
  NO_COLOR                  Disable coloured output.
  COSMONIC_REQUIRE_SANDBOX  Set to 1 so the app refuses to start rather than
                            falling back to --no-sandbox. (Read at launch, not
                            by this script.)

${B}NOTES${N}
  The app is registered ${B}in place${N} — the ~1 GB payload is not copied. Moving
  this directory breaks the install; move it, then re-run ./install.sh.

  Not everything can be done without root. The sandbox, missing system
  libraries, and a C linker for Go components each need an administrator, and
  the app installs and runs without all three. Run --admin-notes for details.

  Further reading: INSTALL.md, next to this script.
EOF
}

# --------------------------------------------------------------- arg parse ---

for arg in "$@"; do
  case "$arg" in
    --prefix=*)     PREFIX="${arg#*=}" ;;
    --sandbox)      SANDBOX_MODE="apparmor" ;;
    --sandbox=*)    SANDBOX_MODE="${arg#*=}" ;;
    --autostart)    DO_AUTOSTART=1 ;;
    --extension)    DO_EXTENSION=yes ;;
    --no-extension) DO_EXTENSION=no ;;
    --uninstall)    UNINSTALL=1 ;;
    --check)        CHECK_ONLY=1 ;;
    --admin-notes)  ADMIN_NOTES_ONLY=1 ;;
    --dry-run|-n)   DRY_RUN=1 ;;
    --force|-f)     FORCE=1 ;;
    --help|-h)      usage; exit 0 ;;
    *)              die "unknown option: $arg (try --help)" ;;
  esac
done

case "$SANDBOX_MODE" in
  report|apparmor|suid|none) ;;
  *) die "--sandbox must be one of: apparmor, suid, none" ;;
esac

BINDIR="$PREFIX/bin"
DESKTOP_DIR="$PREFIX/share/applications"
ICON_DIR="$PREFIX/share/icons/hicolor"
PIXMAP_DIR="$PREFIX/share/pixmaps"
DESKTOP_FILE="$DESKTOP_DIR/$APP_ID.desktop"
AUTOSTART_FILE="$HOME/.config/autostart/$APP_ID.desktop"
EXT_DIR="$HOME/.local/share/gnome-shell/extensions/$EXT_UUID"
APPARMOR_PROFILE="/etc/apparmor.d/$APP_ID"

# ------------------------------------------------------------ admin notes ---

print_admin_notes() {
  cat <<EOF
${B}Cosmonic Desktop — steps that require administrator rights${N}

The application itself installs and runs entirely from a user's home directory
and needs no network. The following are the only privileged items, and each is
optional in the sense that the app still starts without it.

${B}1. Chromium renderer sandbox${N} (recommended; security posture)
   Without one of these, Cosmonic Desktop starts with --no-sandbox and prints a
   warning on every launch. Pick EITHER (a) or (b), once per machine.

   (a) AppArmor profile — preferred, adds no setuid binary.
       Needed on Ubuntu 24.04+ / Debian 13+, where
       kernel.apparmor_restrict_unprivileged_userns=1 is the default.

       sudo tee $APPARMOR_PROFILE >/dev/null <<'PROFILE'
       abi <abi/4.0>,
       include <tunables/global>
       profile $APP_ID "$BIN" flags=(unconfined) {
         userns,
         include if exists <local/$APP_ID>
       }
       PROFILE
       sudo apparmor_parser --replace --write-cache --skip-read-cache $APPARMOR_PROFILE

   (b) setuid helper — for systems without AppArmor (RHEL/CentOS/SLES).

       sudo chown root:root '$SANDBOX_BIN'
       sudo chmod 4755 '$SANDBOX_BIN'

   Note (b) applies to a path inside this user's directory; if the tarball is
   re-extracted or relocated it must be repeated. For multi-user machines,
   extract to a shared read-only location and apply (b) there.

${B}2. Shared libraries${N} (only if the readiness check reported any missing)
   Electron links against the desktop stack. Install the distro packages named
   in the check output, e.g.
       RHEL/Fedora:   sudo dnf install nss atk at-spi2-atk cups-libs libdrm \\
                                       libgbm libxkbcommon alsa-lib gtk3
       Debian/Ubuntu: sudo apt install libnss3 libatk1.0-0 libatk-bridge2.0-0 \\
                                       libcups2 libdrm2 libgbm1 libxkbcommon0 \\
                                       libasound2 libgtk-3-0

${B}3. A host C linker${N} (only if Go components will be built)
   Doctor requires cc/gcc/clang for the Go component path. Rust and JavaScript
   components build without it — the bundled toolchain supplies their linkers.
       RHEL/Fedora:   sudo dnf install gcc
       Debian/Ubuntu: sudo apt install build-essential

${B}Not required:${N} no network access, no package repositories, no service
account, no systemd units, no firewall changes. The daemon runs as the user
over a 0600 unix socket in \$XDG_RUNTIME_DIR and listens on no TCP port.
EOF
}

if [ "$ADMIN_NOTES_ONLY" = 1 ]; then print_admin_notes; exit 0; fi

# ---------------------------------------------------------------- uninstall ---

if [ "$UNINSTALL" = 1 ]; then
  step "Removing $APP_NAME desktop integration"
  for f in "$BINDIR/$APP_ID" "$DESKTOP_FILE" "$AUTOSTART_FILE" \
           "$PIXMAP_DIR/$APP_ID.png"; do
    if [ -e "$f" ] || [ -L "$f" ]; then run rm -f -- "$f" && ok "removed $f"; fi
  done
  while IFS= read -r icon; do
    run rm -f -- "$icon" && ok "removed $icon"
  done < <(find "$ICON_DIR" -name "$APP_ID.png" 2>/dev/null || true)

  if [ -d "$EXT_DIR" ]; then
    command -v gnome-extensions >/dev/null 2>&1 && \
      run gnome-extensions disable "$EXT_UUID" 2>/dev/null || true
    run rm -rf -- "$EXT_DIR" && ok "removed GNOME extension"
  fi

  if [ -f "$APPARMOR_PROFILE" ]; then
    warn "an AppArmor profile remains at $APPARMOR_PROFILE (needs root to remove)"
  fi

  command -v update-desktop-database >/dev/null 2>&1 && \
    run update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
  command -v gtk-update-icon-cache >/dev/null 2>&1 && \
    run gtk-update-icon-cache -f -t "$ICON_DIR" 2>/dev/null || true

  say ""
  say "Uninstalled. Application data was left alone:"
  say "  ${DIM}~/.local/share/cosmonic  ~/.config/cosmonic  ~/.cache/cosmonic${N}"
  say "  ${DIM}Delete this directory to reclaim the ~1 GB payload.${N}"
  exit 0
fi

# -------------------------------------------------------------- preflight ---

step "Checking the package"

[ -x "$BIN" ]       || die "$BIN not found — run this script from inside the unpacked directory"
[ -x "$LAUNCHER" ]  || die "$LAUNCHER not found (the sandbox-aware wrapper is required)"
[ -d "$RESOURCES" ] || die "$RESOURCES not found"
ok "app binary and launcher present"

# Extraction over a network share or onto a noexec mount is a classic air-gap
# transfer casualty and produces a baffling failure much later.
if [ ! -x "$BIN" ] || ! head -c 4 "$BIN" >/dev/null 2>&1; then
  die "$BIN is not readable/executable — check the extraction preserved permissions"
fi
mount_opts="$(findmnt -no OPTIONS --target "$HERE" 2>/dev/null || true)"
case ",$mount_opts," in
  *,noexec,*) die "$HERE is on a noexec mount; extract to a normal home directory" ;;
esac

# Arch check. On a machine of another architecture the ELF simply will not
# exec, and every later step would succeed while producing an install that
# cannot start. Fail here instead of leaving that trap behind.
pkg_arch="$(file -b "$BIN" 2>/dev/null | grep -oE 'x86-64|aarch64|ARM aarch64' | head -1)"
host_arch="$(uname -m)"
case "$host_arch:$pkg_arch" in
  x86_64:x86-64|aarch64:aarch64|aarch64:"ARM aarch64") ok "architecture: $host_arch" ;;
  *:"")  warn "could not determine the package architecture (\`file\` unavailable?)" ;;
  *)
    say "" >&2
    printf '%serror:%s architecture mismatch\n' "$RED" "$N" >&2
    say  "  this package is ${B}${pkg_arch}${N}, this machine is ${B}${host_arch}${N}." >&2
    say  "  The binaries cannot exec here. Obtain the ${host_arch} air-gap tarball." >&2
    say  "  ${DIM}(--force installs the desktop entries anyway; the app will not start.)${N}" >&2
    say "" >&2
    blocker "wrong architecture: package is $pkg_arch, this machine is $host_arch"
    if [ "$CHECK_ONLY" = 1 ]; then
      warn "continuing the report; nothing will be installed"
    elif [ "$FORCE" = 1 ]; then
      warn "--force given; continuing with a non-runnable install"
    else
      exit 1
    fi
    ;;
esac

# Free space. The daemon expands the mirrors into ~/.local/share on first use,
# and on a locked-down box a quota is likelier than a full disk.
avail_kb="$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print $4}')"
if [ -n "${avail_kb:-}" ]; then
  if [ "$avail_kb" -lt 3145728 ]; then
    warn "only $((avail_kb/1024)) MB free in \$HOME; the toolchain seeding needs ~3 GB"
    blocker "free space in \$HOME is $((avail_kb/1024)) MB; the toolchain seeding needs ~3 GB"
  else
    ok "free space in \$HOME: $((avail_kb/1048576)) GB"
  fi
fi

# Report the air-gap payload so the operator knows what the first run can seed
# without network. Missing pieces are a warning, not an error: the lean build
# ships the same tree minus the mirrors and is perfectly installable.
payload_found=0
for t in toolchain-bundle go-mirror rust-mirror; do
  if [ -f "$RESOURCES/$t.tar" ]; then
    ok "offline payload: $t.tar ($(du -h "$RESOURCES/$t.tar" | cut -f1))"
    payload_found=1
  else
    skip "offline payload: $t.tar absent"
  fi
done
if [ "$payload_found" = 0 ]; then
  warn "no offline mirrors found — this looks like a lean (online) build, which"
  say  "     ${DIM}will try to reach the network when you install the toolchain.${N}"
fi

# ------------------------------------------------------- shared libraries ---

# On an air-gapped, non-admin box this is the check that matters most: a
# missing libnss3 is a silent-exit Electron and the user cannot install it
# themselves. Name the packages so they have something concrete to escalate.
step "Checking shared libraries"
if [ "$host_arch:$pkg_arch" != "x86_64:x86-64" ] && \
   [ "$host_arch:$pkg_arch" != "aarch64:aarch64" ] && \
   [ "$host_arch:$pkg_arch" != "aarch64:ARM aarch64" ]; then
  skip "skipped (architecture mismatch makes ldd meaningless here)"
elif ! command -v ldd >/dev/null 2>&1; then
  skip "ldd not available"
else
  missing="$(ldd "$BIN" 2>/dev/null | awk '/not found/{print $1}' | sort -u || true)"
  if [ -z "$missing" ]; then
    ok "all direct dependencies resolve"
  else
    warn "missing shared libraries:"
    printf '%s\n' "$missing" | sed 's/^/       /'
    need_admin "install the shared libraries listed above (see --admin-notes §2)"
    say "     ${DIM}You cannot install these without root. Run --admin-notes for the${N}"
    say "     ${DIM}package names to send to your administrator.${N}"
  fi
fi

if [ "$CHECK_ONLY" = 1 ]; then
  step "Chromium renderer sandbox"
  if [ -f "$SANDBOX_BIN" ] && [ ! -L "$SANDBOX_BIN" ] && [ -u "$SANDBOX_BIN" ] \
     && [ "$(stat -c %u "$SANDBOX_BIN" 2>/dev/null)" = "0" ]; then
    ok "setuid helper configured"
  elif command -v unshare >/dev/null 2>&1 && unshare -Ur true 2>/dev/null; then
    ok "unprivileged user namespaces available"
  else
    warn "unavailable — the app will run with --no-sandbox"
    need_admin "configure Chromium's sandbox (see --admin-notes §1)"
  fi
  step "Host C linker (Go components only)"
  if command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1; then
    ok "present"
  else
    warn "absent — Rust and JavaScript components still build"
    need_admin "install gcc or clang if Go components are needed (--admin-notes §3)"
  fi
  say ""
  if [ "${#BLOCKERS[@]}" -gt 0 ]; then
    step "Blocked — the app will not run here until these are resolved:"
    for item in "${BLOCKERS[@]}"; do say "  ${RED}*${N} $item"; done
    say ""
  fi
  if [ "${#ADMIN_ITEMS[@]}" -gt 0 ]; then
    step "Needs an administrator:"
    for item in "${ADMIN_ITEMS[@]}"; do say "  ${YEL}*${N} $item"; done
    say ""
    say "  ${DIM}The app still installs and starts without these.${N}"
    say ""
  fi
  if [ "${#BLOCKERS[@]}" -eq 0 ] && [ "${#ADMIN_ITEMS[@]}" -eq 0 ]; then
    step "Ready — run ./install.sh to install"
  elif [ "${#BLOCKERS[@]}" -eq 0 ]; then
    step "Ready to install — run ./install.sh"
  fi
  [ "${#BLOCKERS[@]}" -eq 0 ] || exit 1
  exit 0
fi

# ------------------------------------------------------------------ PATH ---

step "Installing the launcher on PATH"
run mkdir -p -- "$BINDIR"
if [ -e "$BINDIR/$APP_ID" ] && [ ! -L "$BINDIR/$APP_ID" ]; then
  die "$BINDIR/$APP_ID exists and is not a symlink; move it aside and re-run"
fi
# Symlink the .sh wrapper, never the ELF: the wrapper resolves its own real path
# so it still finds the app directory through the link, and it is what performs
# the sandbox probe. Symlinking the binary would skip that entirely.
run ln -sfn -- "$LAUNCHER" "$BINDIR/$APP_ID"
ok "$BINDIR/$APP_ID -> $LAUNCHER"

case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) warn "$BINDIR is not on your PATH; add this to ~/.bashrc or ~/.zshrc:"
     say  "     ${DIM}export PATH=\"$BINDIR:\$PATH\"${N}" ;;
esac

# ------------------------------------------------------------------ icon ---

step "Installing the icon"
SRC_ICON="$RESOURCES/icon.png"
if [ ! -f "$SRC_ICON" ]; then
  skip "resources/icon.png missing"
else
  # Prefer real downscales when ImageMagick is around — a 1024px PNG dropped
  # into a 48px slot is what makes launcher icons look soft.
  magick_cmd=""
  command -v magick >/dev/null 2>&1 && magick_cmd="magick"
  [ -z "$magick_cmd" ] && command -v convert >/dev/null 2>&1 && magick_cmd="convert"

  if [ -n "$magick_cmd" ]; then
    for size in 16 24 32 48 64 128 256 512; do
      d="$ICON_DIR/${size}x${size}/apps"
      run mkdir -p -- "$d"
      run "$magick_cmd" "$SRC_ICON" -resize "${size}x${size}" "$d/$APP_ID.png"
    done
    ok "icons rendered at 16-512px into $ICON_DIR"
  else
    d="$ICON_DIR/1024x1024/apps"
    run mkdir -p -- "$d"
    run cp -f -- "$SRC_ICON" "$d/$APP_ID.png"
    run mkdir -p -- "$PIXMAP_DIR"
    run cp -f -- "$SRC_ICON" "$PIXMAP_DIR/$APP_ID.png"
    ok "icon installed at 1024px (ImageMagick would give crisper small sizes)"
  fi
fi

# --------------------------------------------------------- desktop entry ---

step "Installing the desktop entry"
# The filename must be exactly cosmonic-desktop.desktop: the app calls
# setAsDefaultProtocolClient("cosmonic") at runtime, and on Linux that writes
# the x-scheme-handler association against this entry's name.
write_file "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=$APP_NAME
GenericName=WebAssembly Workload Host
Comment=Build and run sandboxed WebAssembly workloads on your machine
Exec=$LAUNCHER %U
Icon=$APP_ID
Terminal=false
Categories=Development;IDE;
Keywords=wasm;webassembly;wasmcloud;cosmonic;component;
StartupNotify=true
StartupWMClass=$APP_ID
MimeType=x-scheme-handler/cosmonic;
EOF
ok "$DESKTOP_FILE"

if [ "$DRY_RUN" = 0 ] && command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$DESKTOP_FILE" && ok "desktop entry validates" || \
    warn "desktop-file-validate reported issues (the entry will still work)"
fi

if [ "$DO_AUTOSTART" = 1 ]; then
  # --hidden is the app's own flag: start into the tray without raising a window.
  write_file "$AUTOSTART_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=$APP_NAME
Exec=$LAUNCHER --hidden
Icon=$APP_ID
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
  ok "autostart enabled ($AUTOSTART_FILE)"
else
  skip "autostart not enabled (pass --autostart)"
fi

command -v update-desktop-database >/dev/null 2>&1 && \
  run update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && \
  run gtk-update-icon-cache -f -t "$ICON_DIR" 2>/dev/null || true

# ------------------------------------------------------- GNOME extension ---

install_gnome_extension() {
  local shell_ver major src
  if ! command -v gnome-shell >/dev/null 2>&1; then
    skip "GNOME Shell not detected"
    return 0
  fi
  shell_ver="$(gnome-shell --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)*' | head -1)"
  major="${shell_ver%%.*}"
  [ -n "$major" ] || { warn "could not parse the GNOME Shell version"; return 0; }

  # GNOME 45 moved extensions to ESM; the two trees here are exactly that split
  # (the legacy one exists for RHEL 9, which ships GNOME 40).
  if [ "$major" -ge 45 ]; then
    src="$RESOURCES/gnome-shell-extension/$EXT_UUID"
  elif [ "$major" -ge 40 ]; then
    src="$RESOURCES/gnome-shell-extension-legacy/$EXT_UUID"
  else
    warn "GNOME Shell $shell_ver predates the extension's support floor (40); skipping"
    return 0
  fi
  [ -d "$src" ] || { warn "extension source missing: $src"; return 0; }

  # Per-user extension dir — no root involved.
  run mkdir -p -- "$(dirname -- "$EXT_DIR")"
  run rm -rf -- "$EXT_DIR"
  run cp -r -- "$src" "$EXT_DIR"
  ok "tray extension installed for GNOME $shell_ver"

  if command -v gnome-extensions >/dev/null 2>&1; then
    if run gnome-extensions enable "$EXT_UUID" 2>/dev/null; then
      ok "extension enabled"
    else
      warn "not enabled yet — GNOME must reload its extension list first"
      say  "     ${DIM}X11: Alt+F2, type 'r', Enter.  Wayland: log out and back in.${N}"
      say  "     ${DIM}Then: gnome-extensions enable $EXT_UUID${N}"
    fi
  fi
}

step "GNOME tray extension"
case "$DO_EXTENSION" in
  no)   skip "skipped (--no-extension)" ;;
  yes)  install_gnome_extension ;;
  auto)
    if [[ "${XDG_CURRENT_DESKTOP:-}" == *GNOME* ]]; then
      install_gnome_extension
    else
      skip "not a GNOME session (pass --extension to install anyway)"
    fi ;;
esac

# ---------------------------------------------------------------- sandbox ---

# Same probe the launcher uses, kept in sync deliberately: if this reports the
# sandbox as configured, cosmonic-desktop.sh will exec the binary directly.
sandbox_available() {
  if [ -f "$SANDBOX_BIN" ] && [ ! -L "$SANDBOX_BIN" ] && [ -u "$SANDBOX_BIN" ] \
     && [ "$(stat -c %u "$SANDBOX_BIN" 2>/dev/null)" = "0" ]; then
    return 0
  fi
  command -v unshare >/dev/null 2>&1 && unshare -Ur true 2>/dev/null && return 0
  return 1
}

configure_apparmor() {
  command -v apparmor_parser >/dev/null 2>&1 || \
    die "apparmor_parser not found; use --sandbox=suid instead"
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<EOF
abi <abi/4.0>,
include <tunables/global>

profile $APP_ID "$BIN" flags=(unconfined) {
  userns,
  include if exists <local/$APP_ID>
}
EOF
  run sudo install -m 0644 "$tmp" "$APPARMOR_PROFILE"
  rm -f "$tmp"
  run sudo apparmor_parser --replace --write-cache --skip-read-cache "$APPARMOR_PROFILE"
  ok "AppArmor profile installed at $APPARMOR_PROFILE"
}

configure_suid() {
  run sudo chown root:root "$SANDBOX_BIN"
  run sudo chmod 4755 "$SANDBOX_BIN"
  ok "chrome-sandbox is now setuid root"
}

step "Chromium renderer sandbox"
if sandbox_available; then
  ok "available — nothing to do"
else
  case "$SANDBOX_MODE" in
    # These two exist for admin-run installs. The default never gets here.
    apparmor) configure_apparmor ;;
    suid)     configure_suid ;;
    none)     skip "left unconfigured (--sandbox=none)" ;;
    report)
      warn "not available on this system"
      say  "     Unprivileged user namespaces are restricted here and chrome-sandbox"
      say  "     is not setuid root. ${B}This needs root once and cannot be fixed by an${N}"
      say  "     ${B}unprivileged user.${N}"
      say  ""
      say  "     The app still runs: the launcher falls back to ${B}--no-sandbox${N} and"
      say  "     prints a notice each time. Chromium's renderer sandbox is separate"
      say  "     from the wasmtime sandbox your workloads execute in — that one is"
      say  "     unaffected and still enforced."
      say  ""
      say  "     To have it fixed: ${B}./install.sh --admin-notes${N} prints the exact"
      say  "     commands for your administrator."
      say  ""
      say  "     ${DIM}To make the fallback a hard failure instead (policy environments):${N}"
      say  "     ${DIM}export COSMONIC_REQUIRE_SANDBOX=1${N}"
      need_admin "configure Chromium's sandbox (see --admin-notes §1)"
      ;;
  esac
fi

# -------------------------------------------------------------- C linker ---

step "Host C linker (needed only for Go components)"
if command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1; then
  ok "present"
else
  warn "no cc/gcc/clang found"
  say  "     Rust and JavaScript components build fine without it — their linkers"
  say  "     come from the bundled toolchain. Only the Go component path needs a"
  say  "     host C linker, and installing one requires root."
  need_admin "install gcc or clang if Go components are needed (--admin-notes §3)"
fi

# ------------------------------------------------------------------- done ---

say ""
step "Installed"
say ""
say "  Launch it:      ${B}$APP_ID${N}   ${DIM}(or from your application menu)${N}"
say "  Readiness:      ${B}./install.sh --check${N}"
say "  For your admin: ${B}./install.sh --admin-notes${N}"
say "  Uninstall:      ${B}./install.sh --uninstall${N}"
say ""
say "  ${B}First run, with no network:${N}"
say "    1. Accept the EULA."
say "    2. Open ${B}Doctor${N} and choose ${B}Install toolchain${N}. That is the step that"
say "       unpacks the bundled mirrors — wash/wkg/wasm-tools from the signed OCI"
say "       bundle, pinned Rust 1.97.1 with the wasm32-wasip2 std, and the patched"
say "       Go 1.25.5 plus componentize-go with a seeded module cache. All local;"
say "       the OCI bundle is still signature-verified against Cosmonic's key."
say "    3. Doctor writes into \$HOME only. No root, no network, no ports."
say ""

if [ "${#BLOCKERS[@]}" -gt 0 ]; then
  say "  ${RED}Unresolved — the app will not run until these are fixed:${N}"
  for item in "${BLOCKERS[@]}"; do say "    ${RED}*${N} $item"; done
  say ""
fi

if [ "${#ADMIN_ITEMS[@]}" -gt 0 ]; then
  say "  ${YEL}Needs an administrator (the app works without these):${N}"
  for item in "${ADMIN_ITEMS[@]}"; do say "    ${YEL}*${N} $item"; done
  say ""
fi

say "  ${DIM}This directory is the install. Moving it breaks the entries above;${N}"
say "  ${DIM}move it, then re-run install.sh.${N}"
say ""
