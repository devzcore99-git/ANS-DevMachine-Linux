#!/usr/bin/env bash
#
# Bootstrap: make this machine able to run the playbook, then run it.
#
# Assumes you already have this repository on the machine — cloned, unzipped,
# scp'd, whatever. The script does not fetch anything from GitHub; it finds the
# playbook next to itself and runs it. Nothing here needs git or network access
# to a repo host, so an unpacked tarball works as well as a checkout.
#
# It installs git, ansible-core and curl if missing, checks the ansible-core
# version, and hands off to ansible-playbook.
#
# Usage:
#   ./bootstrap.sh          # install prerequisites, then offer to run site.yml
#   ./bootstrap.sh -n       # prerequisites only, don't run the playbook
#   ./bootstrap.sh -p x.yml # run a different playbook
#   ./bootstrap.sh -y       # don't prompt, just run it

set -euo pipefail

PLAYBOOK="${PLAYBOOK:-site.yml}"
RUN_PLAYBOOK=1
ASSUME_YES=0

# --- output helpers ---------------------------------------------------------
if [ -t 1 ]; then
    B=$'\033[1m'; R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[0;33m'; N=$'\033[0m'
else
    B=""; R=""; G=""; Y=""; N=""
fi
info() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%swarn%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%sfail%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
bootstrap.sh — install prerequisites and run the workstation playbook.

Run it from the repository you already downloaded; it locates the playbook
relative to its own path and does not clone or fetch anything.

  -p FILE   playbook filename to run (default: site.yml)
  -n        install prerequisites only, do not run the playbook
  -y        do not prompt before running the playbook
  -h        this help
EOF
    exit 0
}

while getopts ":p:nyh" opt; do
    case "$opt" in
        p) PLAYBOOK="$OPTARG" ;;
        n) RUN_PLAYBOOK=0 ;;
        y) ASSUME_YES=1 ;;
        h) usage ;;
        \?) die "unknown option: -$OPTARG (try -h)" ;;
        :)  die "-$OPTARG requires an argument" ;;
    esac
done

# --- locate the repository --------------------------------------------------
# Resolve this script's real path, following symlinks, so the playbook is still
# found when bootstrap.sh is invoked through a symlink somewhere on PATH.
src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
    src_dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    # A relative symlink target is relative to the link's directory, not to $PWD.
    case "$src" in /*) ;; *) src="$src_dir/$src" ;; esac
done
REPO_DIR="$(cd -P "$(dirname "$src")" && pwd)"

playbook_path=""
for candidate in "$REPO_DIR/$PLAYBOOK" "$REPO_DIR/ansible/$PLAYBOOK"; do
    [ -f "$candidate" ] && { playbook_path="$candidate"; break; }
done
[ -n "$playbook_path" ] || die "No $PLAYBOOK beside this script.
     Looked in $REPO_DIR and $REPO_DIR/ansible.
     Run bootstrap.sh from the repository you downloaded, or name a different
     playbook with -p."
ok "playbook found at $playbook_path"

# --- preflight --------------------------------------------------------------
[ "$(id -u)" -eq 0 ] && die "Do not run as root. It needs your real user for the
     user-scoped installs; it calls sudo itself where required."

command -v sudo >/dev/null 2>&1 || die "sudo not found."
command -v apt-get >/dev/null 2>&1 || die "No apt-get. This bootstrap targets
     Debian/Ubuntu, and so does the playbook it runs."

info "Priming sudo (you may be prompted)"
sudo -v || die "sudo authentication failed."

# --- dependencies -----------------------------------------------------------
# curl is not used by this script, but the playbook's Claude Code and OpenCode
# tasks pipe their upstream installers through it.
need=()
command -v git >/dev/null 2>&1 || need+=(git)
command -v ansible-playbook >/dev/null 2>&1 || need+=(ansible-core)
command -v curl >/dev/null 2>&1 || need+=(curl)

if [ ${#need[@]} -gt 0 ]; then
    info "Installing: ${need[*]}"
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}" \
        || die "package install failed"
else
    ok "git, ansible-core and curl already present"
fi

command -v ansible-playbook >/dev/null 2>&1 || die "ansible-playbook still not on PATH"
ok "$(ansible-playbook --version | head -1)"

# deb822_repository, used throughout the playbook, landed in ansible-core 2.15.
acv="$(ansible-playbook --version | sed -n '1s/.*core \([0-9]*\.[0-9]*\).*/\1/p')"
if [ -n "$acv" ] && [ "$(printf '%s\n2.15\n' "$acv" | sort -V | head -1)" != "2.15" ]; then
    warn "ansible-core $acv is older than 2.15; the playbook's deb822_repository
     tasks will fail. Upgrade ansible-core before running the playbook."
fi

# --- run the playbook -------------------------------------------------------
run_hint() {
    printf '\n    cd %s && ansible-playbook %s -K\n\n' \
        "$(dirname "$playbook_path")" "$(basename "$playbook_path")"
}

if [ "$RUN_PLAYBOOK" -eq 0 ]; then
    info "Skipping playbook run (-n). To run it yourself:"; run_hint; exit 0
fi

if [ "$ASSUME_YES" -eq 0 ]; then
    printf '\n'
    read -r -p "Run ${playbook_path#"$REPO_DIR"/} now? [y/N] " reply
    case "$reply" in
        [yY]|[yY][eE][sS]) ;;
        *) info "Skipped. To run it later:"; run_hint; exit 0 ;;
    esac
fi

info "Running playbook (sudo password will be requested)"
# cd so ansible.cfg beside the playbook is picked up: ansible only reads a
# config from the current directory, never from the playbook's directory.
cd "$(dirname "$playbook_path")"
ansible-playbook "$(basename "$playbook_path")" -K
ok "bootstrap complete"
printf '\nLog out and back in to pick up docker/libvirt group membership.\n'
