#!/usr/bin/env bash
#
# Bootstrap: ensure git + ansible-core + gh, authenticate to GitHub with your
# passkey, clone a private repo, run the playbook.
#
# Usage:
#   ./bootstrap.sh                          # interactive
#   ./bootstrap.sh -r owner/repo            # repo on the command line
#   ./bootstrap.sh -r owner/repo -n         # clone but don't run the playbook
#
# Non-interactive (CI): export GH_TOKEN=… to skip the passkey login entirely.
#   GH_TOKEN=ghp_xxx GIT_REPO=owner/repo ./bootstrap.sh
#
# How the passkey is used: git itself cannot invoke a passkey — WebAuthn
# credentials are bound to a browser origin. So `gh auth login --web` runs the
# OAuth device flow: it prints a one-time code, you sign in to github.com with
# your passkey, and gh exchanges that for an OAuth token which it stores and
# wires into git's credential helper. The passkey authenticates you; the token
# it mints is what git actually uses, and gh manages it so you never type one.

set -euo pipefail

# Deliberately not under ~/AI: that is itself a git repo now, and cloning into
# it would nest a checkout inside a checkout. Override with -d.
CLONE_DIR="${CLONE_DIR:-$HOME/ansible-installer-01}"
PLAYBOOK="${PLAYBOOK:-site.yml}"
RUN_PLAYBOOK=1

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

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while getopts ":r:d:np:h" opt; do
    case "$opt" in
        r) GIT_REPO="$OPTARG" ;;
        d) CLONE_DIR="$OPTARG" ;;
        p) PLAYBOOK="$OPTARG" ;;
        n) RUN_PLAYBOOK=0 ;;
        h) usage ;;
        \?) die "unknown option: -$OPTARG (try -h)" ;;
        :)  die "-$OPTARG requires an argument" ;;
    esac
done

# --- preflight --------------------------------------------------------------
[ "$(id -u)" -eq 0 ] && die "Do not run as root. It needs your real user for the
     user-scoped installs and for gh's credential store; it calls sudo itself
     where required."

command -v sudo >/dev/null 2>&1 || die "sudo not found."
command -v apt-get >/dev/null 2>&1 || die "No apt-get. This bootstrap targets
     Debian/Ubuntu, and so does the playbook it runs."

info "Priming sudo (you may be prompted)"
sudo -v || die "sudo authentication failed."

# --- 1. base dependencies ---------------------------------------------------
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

command -v git >/dev/null 2>&1 || die "git still not on PATH after install"
command -v ansible-playbook >/dev/null 2>&1 || die "ansible-playbook still not on PATH"

ok "git $(git --version | awk '{print $3}')"
ok "$(ansible-playbook --version | head -1)"

# deb822_repository, used throughout the playbook, landed in ansible-core 2.15.
acv="$(ansible-playbook --version | sed -n '1s/.*core \([0-9]*\.[0-9]*\).*/\1/p')"
if [ -n "$acv" ] && [ "$(printf '%s\n2.15\n' "$acv" | sort -V | head -1)" != "2.15" ]; then
    warn "ansible-core $acv is older than 2.15; the playbook's deb822_repository
     tasks will fail. Upgrade ansible-core before running the playbook."
fi

# --- 2. GitHub CLI ----------------------------------------------------------
# Ubuntu ships gh, but a stale build (2.46 on 26.04). Use the upstream repo so
# the device-flow login matches current GitHub behaviour.
if ! command -v gh >/dev/null 2>&1; then
    info "Installing GitHub CLI from cli.github.com"
    # Pin the source to this machine's dpkg architecture rather than assuming
    # amd64 — cli.github.com publishes amd64, arm64, armhf and i386. Unquoted
    # heredoc below so deb_arch expands; nothing else in it uses $.
    deb_arch="$(dpkg --print-architecture)"
    sudo install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null \
        || die "could not fetch the GitHub CLI signing key"
    sudo chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg
    sudo tee /etc/apt/sources.list.d/github-cli.sources >/dev/null <<EOF
Types: deb
URIs: https://cli.github.com/packages
Suites: stable
Components: main
Architectures: ${deb_arch}
Signed-By: /etc/apt/keyrings/githubcli-archive-keyring.gpg
Enabled: yes
EOF
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gh \
        || die "gh install failed"
fi
ok "$(gh --version | head -1)"

# --- 3. authenticate --------------------------------------------------------
if [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; then
    info "Using token from the environment (skipping passkey login)"
elif gh auth status --hostname github.com >/dev/null 2>&1; then
    ok "already authenticated to github.com"
else
    info "Authenticating with GitHub"
    printf '\n  A one-time code will be shown below. Open the URL it prints,\n'
    printf '  enter the code, and approve with your passkey.\n\n'
    # --web runs the OAuth device flow; the passkey is presented to github.com
    # in the browser, not to this script. 'repo' scope covers private clones.
    gh auth login --hostname github.com --git-protocol https --web --scopes repo \
        || die "GitHub authentication failed or was cancelled"
fi

# Point git's credential helper at gh, so plain 'git clone/pull' authenticates
# with the stored OAuth token and no credentials land in .git/config.
gh auth setup-git --hostname github.com || die "gh auth setup-git failed"

gh_user="$(gh api user --jq .login 2>/dev/null || echo '')"
[ -n "$gh_user" ] && ok "authenticated as $gh_user"

# No scope pre-check here on purpose: gh's auth status output is not a stable
# contract to grep, and the 'gh repo view' check below tests real access to the
# real repo, which is what actually matters. Its failure message covers scope.

# --- 4. repository ----------------------------------------------------------
if [ -z "${GIT_REPO:-}" ]; then
    printf '\n'
    read -r -p "GitHub repository (owner/repo or full URL): " GIT_REPO
fi
[ -n "$GIT_REPO" ] || die "no repository given"

# Normalise owner/repo, https://… and git@… all to an https URL.
case "$GIT_REPO" in
    git@github.com:*)      slug="${GIT_REPO#git@github.com:}" ;;
    https://github.com/*)  slug="${GIT_REPO#https://github.com/}" ;;
    http://github.com/*)   slug="${GIT_REPO#http://github.com/}" ;;
    *://*|git@*)           die "only github.com is supported, got '$GIT_REPO'.
     This bootstrap authenticates via the GitHub CLI." ;;
    */*)                   slug="$GIT_REPO" ;;
    *) die "cannot parse '$GIT_REPO'. Use owner/repo or a github.com URL." ;;
esac
slug="${slug%.git}"; slug="${slug%/}"
case "$slug" in
    */*/*) die "'$GIT_REPO' has too many path segments; expected owner/repo" ;;
    */*)   : ;;
    *)     die "cannot parse '$GIT_REPO'. Use owner/repo or a github.com URL." ;;
esac
REPO_URL="https://github.com/${slug}.git"

info "Verifying access to $slug"
if ! gh repo view "$slug" --json nameWithOwner >/dev/null 2>&1; then
    die "Cannot reach $slug as ${gh_user:-this account}. Check that:
       - the repo exists and is spelled correctly
       - this account has access to it
       - the session has the 'repo' scope:  gh auth refresh -h github.com -s repo
       - if the owning org enforces SSO, the session is authorised for that org"
fi
ok "repo reachable"

# --- 5. clone or update -----------------------------------------------------
if [ -d "$CLONE_DIR/.git" ]; then
    existing="$(git -C "$CLONE_DIR" remote get-url origin 2>/dev/null || echo '')"
    if [ "$existing" != "$REPO_URL" ]; then
        die "$CLONE_DIR already holds a different repo:
       $existing
     Move it aside, or pass a different target with -d."
    fi
    info "Updating existing checkout at $CLONE_DIR"
    git -C "$CLONE_DIR" pull --ff-only || die "pull failed (local changes?)"
elif [ -e "$CLONE_DIR" ] && [ -n "$(ls -A "$CLONE_DIR" 2>/dev/null)" ]; then
    die "$CLONE_DIR exists and is not empty. Move it aside, or use -d."
else
    info "Cloning into $CLONE_DIR"
    mkdir -p "$(dirname "$CLONE_DIR")"
    git clone "$REPO_URL" "$CLONE_DIR" || die "clone failed"
fi
ok "checkout ready at $CLONE_DIR"

# --- 6. run the playbook ----------------------------------------------------
playbook_path=""
for candidate in "$CLONE_DIR/$PLAYBOOK" "$CLONE_DIR/ansible/$PLAYBOOK"; do
    [ -f "$candidate" ] && { playbook_path="$candidate"; break; }
done

if [ -z "$playbook_path" ]; then
    warn "No $PLAYBOOK found in $CLONE_DIR (or its ansible/ subdirectory).
     Nothing to run. Use -p to name a different playbook."
    exit 0
fi

run_hint() {
    printf '\n    cd %s && ansible-playbook %s -K\n\n' \
        "$(dirname "$playbook_path")" "$(basename "$playbook_path")"
}

if [ "$RUN_PLAYBOOK" -eq 0 ]; then
    info "Skipping playbook run (-n). To run it yourself:"; run_hint; exit 0
fi

printf '\n'
read -r -p "Run ${playbook_path#"$CLONE_DIR"/} now? [y/N] " reply
case "$reply" in
    [yY]|[yY][eE][sS])
        info "Running playbook (sudo password will be requested)"
        cd "$(dirname "$playbook_path")"
        ansible-playbook "$(basename "$playbook_path")" -K
        ok "bootstrap complete"
        printf '\nLog out and back in to pick up docker/libvirt group membership.\n'
        ;;
    *)
        info "Skipped. To run it later:"; run_hint
        ;;
esac
