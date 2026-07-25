# Workstation provisioning

Ansible playbook for Ubuntu 26.04 (resolute) on **amd64 (x86_64) or arm64 (aarch64)**. Uses `ansible.builtin` modules only — no Galaxy collections to install.

The same set of software installs on both: every third-party repo used here publishes an arm64 index, so nothing is skipped or substituted depending on the machine. See [Architecture](#architecture) for what varies.

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
| FUSE 2 (AppImage runtime) | Ubuntu archive |
| Claude Code | native installer (default) or Anthropic apt repo |
| OpenCode | `opencode.ai/install` → `~/.opencode/bin` |

## Architecture

The playbook resolves the target's architecture with `dpkg --print-architecture` and asserts it appears in `supported_deb_architectures` (`amd64`, `arm64`) before touching anything. It uses that value — not `ansible_architecture` — because apt names architectures `amd64`/`arm64` while the kernel says `x86_64`/`aarch64`, and the two only agree by coincidence.

Everything the playbook installs is available on both. Two things differ:

| | amd64 | arm64 |
|---|---|---|
| Apt repo pins | `Architectures: amd64` | `Architectures: arm64` |
| QEMU emulator | `qemu-system-x86` | `qemu-system-arm` |
| Guest UEFI firmware | `ovmf` | `qemu-efi-aarch64` (AAVMF) |
| Virtualization probe | `vmx`/`svm` in `/proc/cpuinfo` | presence of `/dev/kvm` |

The KVM package split lives in `kvm_packages_common` / `kvm_packages_by_arch` in `group_vars/all.yml`; adding a platform means adding a key there and to `supported_deb_architectures`.

The virtualization probe differs because arm64 has no CPU flag for it. KVM on arm64 depends on the kernel having been entered at EL2, which the firmware decides and which `/proc/cpuinfo` does not report — so `/dev/kvm` is the only honest signal. Either way a missing capability is a warning, not a failure: packages still install and guests fall back to software emulation.

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

Tags: `docker`, `kvm`, `brave`, `chrome`, `vscode`, `codium`, `git`, `btop`, `appimage`, `ai`, `claude`, `opencode`, plus groups `base`, `browsers`, `editors`.

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
- **FUSE 2** is what AppImages need to mount themselves; without it they exit on `dlopen(): error loading libfuse.so.2`. Nothing else pulls it in now that the archive has moved to FUSE 3. The package is `libfuse2t64` on Ubuntu 24.04+ and `libfuse2` before that (the 64-bit `time_t` rename); the playbook probes for the right one rather than guessing from the release number.
- **OpenCode's installer** appends to shell rc files itself; the playbook also ensures `~/.profile` has the PATH entry and guards the install with `creates:` so it runs once.
- **Apt sources pin an architecture explicitly.** Without a pin, apt queries each third-party repo for every foreign architecture `dpkg` has enabled — `i386` is commonly enabled by Steam or Wine — and hard-fails on the index it doesn't find.
- **Claude Code and OpenCode install via upstream scripts** that detect the architecture themselves, so the `native` path needs nothing arch-specific from the playbook.
