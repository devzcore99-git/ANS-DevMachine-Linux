# ANS-DevMachine-Linux

Ansible provisioning for an Ubuntu developer workstation — Docker, KVM,
browsers, editors and AI CLIs from a single playbook.

Targets Ubuntu 24.04 (noble) through 26.04 (resolute) on **amd64** or **arm64**.
Uses `ansible.builtin` modules only, so there are no Galaxy collections to
install. The full detail lives in [`ansible/README.md`](ansible/README.md); this
page is the short version.

## What it provisions

| Component | Source |
|---|---|
| Docker CE + compose/buildx plugins | `download.docker.com` apt repo |
| KVM — qemu, libvirt, virt-manager | Ubuntu archive |
| Brave | `brave-browser-apt-release.s3.brave.com` |
| Google Chrome | `dl.google.com/linux/chrome/deb` |
| VS Code | `packages.microsoft.com/repos/code` |
| VSCodium | `download.vscodium.com/debs` |
| Git, btop | Ubuntu archive |
| FUSE 2 runtime (for AppImages) | Ubuntu archive |
| Tailscale | `pkgs.tailscale.com/stable/<distro>/<codename>` |
| Claude Code | native installer (default) or Anthropic apt repo |
| OpenCode | `opencode.ai/install` → `~/.opencode/bin` |

Every component is behind an `install_*` toggle in
`ansible/group_vars/all.yml`, and all of them default to on.

## Setup

Get this repository onto the target machine yourself — clone, zip, `scp`, USB
stick. `bootstrap.sh` fetches nothing from GitHub; it finds the playbook next to
its own resolved path, so an unpacked archive works exactly like a checkout.

Prerequisites: Ubuntu/Debian with `apt-get` and `sudo`, a non-root user with
sudo rights, and `ansible-core` **2.15+** (older versions lack
`deb822_repository` and the run will fail partway through). `bootstrap.sh`
installs `git`, `ansible-core` and `curl` if they are missing.

## Usage

The bootstrapper is the intended entry point. Run it as your normal user — it
refuses to run as root, because the Claude Code and OpenCode installs need a
real user's home directory:

```bash
./bootstrap.sh          # checklist of components, then offer to run site.yml
./bootstrap.sh -s       # skip the menu, install the group_vars defaults
./bootstrap.sh -y       # never prompt (implies -s)
./bootstrap.sh -n       # install prerequisites only, don't run the playbook
./bootstrap.sh -p x.yml # run a different playbook
```

To run the playbook directly, **you must be inside `ansible/`**:

```bash
cd ansible
ansible-playbook site.yml
```

> **Run it from `ansible/`, not from the repo root.** Ansible reads
> `ansible.cfg` from the current directory only — never from the playbook's
> directory — and `ansible/ansible.cfg` is what sets `inventory = inventory.ini`.
> Run `ansible-playbook ansible/site.yml` from the repo root and the inventory
> is never loaded, so the `workstation` group is empty, `hosts: workstation`
> matches nothing, and Ansible **skips the play and exits 0**. You get a green
> run and a machine that was never touched. There is no error to notice: the
> same missing config also drops `become_ask_pass`, so even the absent sudo
> prompt looks like a cached credential rather than a warning.
>
> If you genuinely need to run from the root, pass both the inventory and `-K`
> by hand — `ansible-playbook -i ansible/inventory.ini -K ansible/site.yml` —
> and accept that the rest of `ansible.cfg` (output formatting, prompt label) is
> not applied. `cd ansible` is the supported path; `bootstrap.sh` does exactly
> that before invoking `ansible-playbook`.

No flags are needed from `ansible/`: `ansible.cfg` sets `become_ask_pass`, so
the playbook asks for your sudo password itself. Dry run first with
`--check --diff`.

### Selective runs

```bash
ansible-playbook site.yml --tags docker,kvm
ansible-playbook site.yml --skip-tags ai
ansible-playbook site.yml -e install_chrome=false
ansible-playbook site.yml -e @selection.local.yml   # repeat a menu selection
```

Tags: `docker`, `kvm`, `brave`, `chrome`, `vscode`, `codium`, `git`, `btop`,
`appimage`, `ai`, `claude`, `opencode`, `tailscale`, plus the groups `base`,
`browsers`, `editors`, `network`.

## What to expect

- **A sudo prompt from the playbook**, always. On a first run `bootstrap.sh`
  prompts separately for its own `apt-get`, so twice — deliberately; sudo's
  credential cache cannot be reused across Ansible's pty-less become subprocess.
- **A first run takes a while.** Each newly-added repo triggers its own
  `apt-get update`, and there are seven of them.
- **Idempotent afterwards.** Every `command`/`shell` task is guarded with
  `changed_when: false`, a conditional `changed_when`, or `creates:`.
- **Group membership does not apply to your current session.** Log out and back
  in (or `newgrp docker`) before using Docker without sudo.
- **Tailscale is installed and started but not joined.** Run `sudo tailscale up`
  afterwards, or pass `-e tailscale_authkey=tskey-auth-...` to join unattended.
- **Claude Code needs authenticating** — run `claude` once.
- **A missing virtualization capability is a warning, not a failure.** Packages
  install anyway and guests fall back to software emulation.

## Notes

- `docker_add_user_to_group` defaults to `true`, which is effectively root on
  this host — anyone in the `docker` group can mount `/` into a container. Set
  it to `false` to keep Docker sudo-only.
- `docker_purge_distro_packages` defaults to `false`; set it to `true` only if
  you want `docker.io`/`podman-docker`/`containerd` removed first.
- Repositories are written as deb822 `.sources`. Chrome and VS Code try to
  re-register their own legacy `.list`; the playbook opts out via `/etc/default/*`
  and deletes any duplicate, because two keyrings for one URI is a hard apt
  failure that breaks every later task.
- Ubuntu 25.10+ puts sudo-rs behind `/usr/bin/sudo`, which breaks Ansible's
  become prompt matching. `ansible_become_exe` probes for classic sudo at
  `/usr/bin/sudo.ws` and falls back to plain `sudo`.
- On Ubuntu derivatives whose codename differs from upstream (Mint 22 is Ubuntu
  24.04 but reports `wilma`), Tailscale's repo URL will 404 — set
  `-e tailscale_repo_distribution=ubuntu -e tailscale_repo_suite=noble`.
