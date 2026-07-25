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
#   ./bootstrap.sh          # choose components, then offer to run site.yml
#   ./bootstrap.sh -s       # skip the menu, install the group_vars defaults
#   ./bootstrap.sh -n       # prerequisites only, don't run the playbook
#   ./bootstrap.sh -p x.yml # run a different playbook
#   ./bootstrap.sh -y       # don't prompt at all (implies -s)

set -euo pipefail

PLAYBOOK="${PLAYBOOK:-site.yml}"
RUN_PLAYBOOK=1
ASSUME_YES=0
USE_MENU=1
selection_file=""

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

  -s        skip the menu, install the defaults from group_vars/all.yml
  -p FILE   playbook filename to run (default: site.yml)
  -n        install prerequisites only, do not run the playbook
  -y        do not prompt at all; implies -s
  -h        this help

By default it asks which components to install. The choices are written to
selection.local.yml beside the playbook and passed with -e, and they pre-select
the menu next time. Re-run that file directly to repeat a selection without the
menu:

  ansible-playbook site.yml -e @selection.local.yml
EOF
    exit 0
}

while getopts ":p:nysh" opt; do
    case "$opt" in
        p) PLAYBOOK="$OPTARG" ;;
        n) RUN_PLAYBOOK=0 ;;
        # Unattended means unattended: a checklist nobody can answer would hang
        # the run, so -y turns the menu off as well as the confirmation.
        y) ASSUME_YES=1; USE_MENU=0 ;;
        s) USE_MENU=0 ;;
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

# Escalate with the same binary the playbook will use, mirroring the probe
# behind ansible_become_exe in group_vars/all.yml, so the two cannot disagree
# about which sudo they mean.
if [ -x /usr/bin/sudo.ws ]; then SUDO=/usr/bin/sudo.ws; else SUDO=sudo; fi

# --- dependencies -----------------------------------------------------------
# Work out what is missing *before* escalating. On a machine that already has
# these — every run after the first — this script needs no privileges at all,
# and the playbook can do the one and only password prompt itself.
#
# curl is not used by this script, but the playbook's Claude Code and OpenCode
# tasks pipe their upstream installers through it.
need=()
command -v git >/dev/null 2>&1 || need+=(git)
command -v ansible-playbook >/dev/null 2>&1 || need+=(ansible-core)
command -v curl >/dev/null 2>&1 || need+=(curl)

if [ ${#need[@]} -gt 0 ]; then
    info "Installing: ${need[*]} (you may be prompted for sudo)"
    "$SUDO" apt-get update -qq
    "$SUDO" DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}" \
        || die "package install failed"

    # The playbook will ask again. Nothing is carried over deliberately: the
    # only ways to avoid the second prompt are to hold the password somewhere
    # for ansible to read, or to lean on sudo's credential cache — which does
    # not work anyway, since tty_tickets binds the ticket to the terminal and
    # ansible runs become from a subprocess with no pty. Typing it twice on a
    # first run is the better trade.
    info "Prerequisites installed. The playbook will ask for sudo separately."
else
    ok "git, ansible-core and curl already present (no sudo needed here)"
fi

command -v ansible-playbook >/dev/null 2>&1 || die "ansible-playbook still not on PATH"
ok "$(ansible-playbook --version | head -1)"

# deb822_repository, used throughout the playbook, landed in ansible-core 2.15.
acv="$(ansible-playbook --version | sed -n '1s/.*core \([0-9]*\.[0-9]*\).*/\1/p')"
if [ -n "$acv" ] && [ "$(printf '%s\n2.15\n' "$acv" | sort -V | head -1)" != "2.15" ]; then
    warn "ansible-core $acv is older than 2.15; the playbook's deb822_repository
     tasks will fail. Upgrade ansible-core before running the playbook."
fi

# --- component menu ---------------------------------------------------------
# The menu is generated from the install_* toggles in group_vars/all.yml rather
# than from a list kept here, so adding a component to the playbook adds it to
# the menu. A toggle is offered only if it carries a `## label` marker.
#
# awk, not sed: this has to cope with both GNU and BSD userlands, and BSD sed
# has no alternation in its default (basic) regex dialect.
vars_file="$(dirname "$playbook_path")/group_vars/all.yml"

menu_catalog() {
    awk -F'##' '
        /^install_[a-z0-9_]+:[[:space:]]*(true|false)/ && NF > 1 {
            split($1, kv, ":")
            gsub(/[[:space:]]/, "", kv[1])
            gsub(/[[:space:]]/, "", kv[2])
            label = $2
            sub(/^[[:space:]]+/, "", label)
            sub(/[[:space:]]+$/, "", label)
            print kv[1] "\t" kv[2] "\t" label
        }
    ' "$1"
}

names=(); labels=(); states=()

load_catalog() {
    local var def label
    while IFS=$'\t' read -r var def label; do
        names+=("$var")
        labels+=("$label")
        if [ "$def" = "true" ]; then states+=(1); else states+=(0); fi
    done < <(menu_catalog "$vars_file")
}

# Start the menu from last run's answers rather than the project defaults, so
# re-running to change one thing does not mean re-ticking everything. Only keys
# present in the file are applied: a component added to the playbook since the
# file was written keeps its default rather than being silently dropped.
apply_saved_selection() {
    local saved i val
    saved="$(dirname "$playbook_path")/selection.local.yml"
    [ -f "$saved" ] || return 0
    for i in "${!names[@]}"; do
        val=$(awk -v k="${names[$i]}:" '$1 == k { print $2 }' "$saved" | tail -1)
        case "$val" in
            true)  states[$i]=1 ;;
            false) states[$i]=0 ;;
        esac
    done
    info "starting from your previous selection ($(basename "$saved"))"
}

# whiptail writes the chosen tags to stderr and draws on stdout, hence the 3>&1
# 1>&2 2>&3 dance. --separate-output gives one bare tag per line instead of the
# default quoted single line, which would need re-parsing.
menu_whiptail() {
    local args=() chosen i height list
    for i in "${!names[@]}"; do
        args+=("${names[$i]}" "${labels[$i]}")
        if [ "${states[$i]}" -eq 1 ]; then args+=(ON); else args+=(OFF); fi
    done

    list=${#names[@]}
    [ "$list" -gt 14 ] && list=14
    height=$((list + 8))

    chosen=$(whiptail --title "Workstation components" --separate-output \
        --checklist "Space toggles, Enter confirms, Esc cancels." \
        "$height" 74 "$list" "${args[@]}" 3>&1 1>&2 2>&3) || return 1

    for i in "${!names[@]}"; do
        if printf '%s\n' "$chosen" | grep -qxF "${names[$i]}"; then
            states[$i]=1
        else
            states[$i]=0
        fi
    done
}

# Fallback for machines without whiptail. Same result, no dependencies.
menu_plain() {
    local reply i n
    while true; do
        printf '\n%sComponents to install%s\n\n' "$B" "$N"
        for i in "${!names[@]}"; do
            printf '  %2d) [%s] %s\n' \
                "$((i + 1))" "$([ "${states[$i]}" -eq 1 ] && printf 'x' || printf ' ')" \
                "${labels[$i]}"
        done
        printf '\n'
        read -r -p "Number to toggle, 'a' all, 'n' none, Enter to accept: " reply || reply=""
        case "$reply" in
            "")  return 0 ;;
            a|A) for i in "${!names[@]}"; do states[$i]=1; done ;;
            n|N) for i in "${!names[@]}"; do states[$i]=0; done ;;
            *[!0-9]*) warn "not a number: $reply" ;;
            *)
                n=$((reply - 1))
                if [ "$n" -ge 0 ] && [ "$n" -lt "${#names[@]}" ]; then
                    if [ "${states[$n]}" -eq 1 ]; then states[$n]=0; else states[$n]=1; fi
                else
                    warn "out of range: $reply"
                fi
                ;;
        esac
    done
}

write_selection() {
    local i out
    out="$(dirname "$playbook_path")/selection.local.yml"
    {
        echo "---"
        echo "# Written by bootstrap.sh. Edit freely, or delete to fall back"
        echo "# to the defaults in group_vars/all.yml."
        for i in "${!names[@]}"; do
            if [ "${states[$i]}" -eq 1 ]; then
                printf '%s: true\n' "${names[$i]}"
            else
                printf '%s: false\n' "${names[$i]}"
            fi
        done
    } > "$out"
    selection_file="$out"
}

run_menu() {
    [ -f "$vars_file" ] || { warn "no group_vars/all.yml beside the playbook; skipping menu"; return 0; }

    load_catalog
    if [ "${#names[@]}" -eq 0 ]; then
        warn "no '## label' toggles found in $vars_file; skipping menu"
        return 0
    fi

    # A menu needs someone to answer it. Without a terminal — a pipe, cron, CI —
    # fall through to the playbook defaults rather than blocking or guessing.
    # This matters more now the menu is the default: it is what keeps an
    # unattended `./bootstrap.sh` from hanging forever on a checklist.
    if [ ! -t 0 ]; then
        warn "not a terminal; skipping menu and using defaults"
        return 0
    fi

    apply_saved_selection

    if command -v whiptail >/dev/null 2>&1; then
        menu_whiptail || { info "Menu cancelled; nothing was changed."; exit 0; }
    else
        menu_plain
    fi

    write_selection
    ok "selection written to ${selection_file#"$REPO_DIR"/}"
}

if [ "$USE_MENU" -eq 1 ]; then
    run_menu
fi

# --- run the playbook -------------------------------------------------------
# No -K in the hint: ansible.cfg sets become_ask_pass, so a standalone run
# needs no flags to get a password prompt.
run_hint() {
    if [ -n "$selection_file" ]; then
        printf '\n    cd %s && ansible-playbook %s -e @%s\n\n' \
            "$(dirname "$playbook_path")" "$(basename "$playbook_path")" \
            "$(basename "$selection_file")"
    else
        printf '\n    cd %s && ansible-playbook %s\n\n' \
            "$(dirname "$playbook_path")" "$(basename "$playbook_path")"
    fi
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

# cd so ansible.cfg beside the playbook is picked up: ansible only reads a
# config from the current directory, never from the playbook's directory.
cd "$(dirname "$playbook_path")"
pb_args=("$(basename "$playbook_path")")
if [ -n "$selection_file" ]; then
    pb_args+=(-e "@$(basename "$selection_file")")
fi

# Pin become to the same sudo this script resolved. group_vars probes for the
# same path, so this only guards against the two probes disagreeing.
pb_args+=(-e "ansible_become_exe=$SUDO")

# ansible.cfg sets become_ask_pass, so the playbook prompts for itself. Nothing
# here suppresses or pre-fills that: the password is entered where it is used
# and is never written down or passed on.
info "Running playbook (it will ask for your sudo password)"
ansible-playbook "${pb_args[@]}"
ok "bootstrap complete"
printf '\nLog out and back in to pick up docker/libvirt group membership.\n'
