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
| Tailscale | `pkgs.tailscale.com/stable/<distro>/<codename>` |
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

Get this repository onto the machine yourself — `git clone`, a downloaded zip, `scp`, a USB stick, whatever suits. Then run `bootstrap.sh` from it:

```bash
./bootstrap.sh        # install prerequisites, then offer to run site.yml
./bootstrap.sh -y     # don't prompt, just run it
./bootstrap.sh -n     # prerequisites only, don't run the playbook
./bootstrap.sh -p x.yml
```

Flags: `-p` playbook name, `-n` no run, `-y` no prompt, `-h` help.

The script installs `git`, `ansible-core` and `curl` if they're missing, warns if `ansible-core` is older than 2.15, then runs the playbook. **It fetches nothing from GitHub** and needs no authentication — it locates the playbook relative to its own path, so an unpacked archive works exactly like a checkout. It resolves symlinks on the way, so it also works symlinked onto your `PATH`.

It refuses to run as root: the playbook needs your real user for the user-scoped installs (Claude Code, OpenCode) and calls `sudo` itself where required.

## Requirements

`ansible-core` 2.15+ (for `deb822_repository`). `bootstrap.sh` installs it, or:

```bash
sudo apt install ansible-core
```

## Run

To run the playbook directly, without `bootstrap.sh`:

```bash
cd ansible          # from the root of this repository
ansible-playbook site.yml -K
```

`-K` prompts for the sudo password. Dry run first with `--check --diff`.

Run it from the `ansible/` directory. Ansible reads `ansible.cfg` from the current directory, never from the playbook's, and this one sets `become_exe` and the inventory — pointing at `ansible/site.yml` from elsewhere silently skips all of it.

## Selective runs

Tags: `docker`, `kvm`, `brave`, `chrome`, `vscode`, `codium`, `git`, `btop`, `appimage`, `ai`, `claude`, `opencode`, `tailscale`, plus groups `base`, `browsers`, `editors`, `network`.

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
- **Tailscale installs and starts `tailscaled`, but does not join a tailnet.** Bare `tailscale up` blocks on an interactive browser login, which would hang an unattended run — connect afterwards with `sudo tailscale up`. To join during provisioning, pass a key on the command line rather than committing one: `ansible-playbook site.yml -K -e tailscale_authkey=tskey-auth-...` (add flags via `tailscale_up_args`, e.g. `--ssh --advertise-exit-node`). The task is skipped when the node is already `Running`, and runs `no_log` so the key stays out of the output.
- **Tailscale's repo URL contains the distro name and codename** (`stable/ubuntu/noble`), unlike the other repos here, which serve one URI for all releases. Derivatives report their own codename — Mint 22 *is* Ubuntu 24.04 but says `wilma` — and there is no repo for it, so on those set `tailscale_repo_distribution` / `tailscale_repo_suite` to the upstream release.
