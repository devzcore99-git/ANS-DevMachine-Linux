# Workstation provisioning

Ansible playbook for Ubuntu 26.04 (resolute) / amd64. Uses `ansible.builtin` modules only — no Galaxy collections to install.

## Installs

| Component | Source |
|---|---|
| Docker CE + compose/buildx | `download.docker.com` apt repo |
| KVM (qemu, libvirt, virt-manager) | Ubuntu archive |
| Brave | `brave-browser-apt-release.s3.brave.com` |
| Chrome | `dl.google.com/linux/chrome/deb` |
| VS Code | `packages.microsoft.com/repos/code` |
| VSCodium | `download.vscodium.com/debs` |
| btop, Git | Ubuntu archive |
| Claude Code | native installer (default) or Anthropic apt repo |
| OpenCode | `opencode.ai/install` → `~/.opencode/bin` |

## Bootstrap a fresh machine

`bootstrap.sh` takes a clean Ubuntu box to a provisioned one. It installs `git`, `ansible-core` and `gh`, signs you in to GitHub **with your passkey**, clones this repo, and offers to run the playbook.

```bash
./bootstrap.sh                    # prompts for the repo
./bootstrap.sh -r owner/repo      # repo up front
./bootstrap.sh -r owner/repo -n   # clone only, don't run the playbook
```

Flags: `-r` repo, `-d` clone dir (default `~/ansible-installer-01`), `-p` playbook name, `-n` no run, `-h` help.

Copy it to the new machine by hand (scp, USB, paste) — it can't be `curl | bash`-ed from the private repo it's the key to.

### On passkeys

Git cannot use a passkey directly: WebAuthn credentials are bound to a browser origin, and Git's HTTPS transport has no way to invoke one. GitHub only accepts a passkey at the website.

So the script runs `gh auth login --web`, the OAuth device flow. It prints a one-time code, you approve on github.com with your passkey, and `gh` stores the resulting OAuth token and wires it into git's credential helper. **Your passkey does the authenticating; the token it mints is what git uses** — you just never type or handle one. Nothing is written to `.git/config`.

For CI, export `GH_TOKEN` to skip the login entirely.

If a clone fails on scope, run `gh auth refresh -h github.com -s repo`.

## Requirements

`ansible-core` 2.15+ (for `deb822_repository`). `bootstrap.sh` installs it, or:

```bash
sudo apt install ansible-core
```

## Run

```bash
cd ~/AI/ansible
ansible-playbook site.yml -K
```

`-K` prompts for the sudo password. Dry run first with `--check --diff`.

## Selective runs

Tags: `docker`, `kvm`, `brave`, `chrome`, `vscode`, `codium`, `git`, `btop`, `ai`, `claude`, `opencode`, plus groups `base`, `browsers`, `editors`.

```bash
ansible-playbook site.yml -K --tags docker,kvm
ansible-playbook site.yml -K --skip-tags ai
```

Toggles and defaults live in `group_vars/all.yml`; override per-run with `-e`:

```bash
ansible-playbook site.yml -K -e install_chrome=false
ansible-playbook site.yml -K -e claude_code_install_method=apt
```

## Notes

- **Repos are deb822 `.sources`**, not legacy `.list`. Chrome and VS Code packages try to re-register their own `.list` file; the playbook opts out via `/etc/default/*` and deletes any duplicate that appears.
- **`docker_add_user_to_group: true`** puts you in the `docker` group, which is effectively root on this host. Set it to `false` to keep Docker sudo-only.
- **Group changes need a new login session.** `newgrp docker` works for the current shell.
- **`docker_purge_distro_packages`** defaults to `false`. Set it to `true` only if you want `docker.io`/`podman-docker`/`containerd` removed first.
- **Claude Code** defaults to `native` (`~/.local/bin/claude`, self-updating) because that matches the existing install on this box. The `apt` method installs system-wide to `/usr/bin` and updates via `apt upgrade` — but `~/.local/bin` usually precedes `/usr/bin` in `PATH`, so remove the native install first (`rm -f ~/.local/bin/claude && rm -rf ~/.local/share/claude`) or you'll have two.
- **OpenCode's installer** appends to shell rc files itself; the playbook also ensures `~/.profile` has the PATH entry and guards the install with `creates:` so it runs once.
