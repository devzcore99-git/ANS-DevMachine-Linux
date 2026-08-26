# Workstation provisioning

Ansible playbook for Ubuntu 24.04 (noble) through 26.04 (resolute) on **amd64 (x86_64) or arm64 (aarch64)**. Uses `ansible.builtin` modules only — no Galaxy collections to install.

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
| GitHub CLI (`gh`) | `cli.github.com/packages` |
| btop, Git | Ubuntu archive |
| FUSE 2 (AppImage runtime) | Ubuntu archive |
| Tailscale | `pkgs.tailscale.com/stable/<distro>/<codename>` |
| Claude Code | native installer (default) or Anthropic apt repo |
| OpenCode | `opencode.ai/install` → `~/.opencode/bin` |
| Herdr | `herdr.dev/install.sh` → `~/.local/bin` |
| DevPod CLI | GitHub release binary → `/usr/local/bin` |

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
./bootstrap.sh        # choose components, then offer to run site.yml
./bootstrap.sh -s     # skip the menu, install the defaults
./bootstrap.sh -y     # don't prompt at all (implies -s)
./bootstrap.sh -n     # prerequisites only, don't run the playbook
./bootstrap.sh -p x.yml
```

Flags: `-s` skip menu, `-p` playbook name, `-n` no run, `-y` no prompt, `-h` help.

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
ansible-playbook site.yml
```

No flags needed: `ansible.cfg` sets `become_ask_pass`, so it prompts for the sudo password on its own. `-K` is harmless if you're used to typing it. Dry run first with `--check --diff`.

Run it from the `ansible/` directory. Ansible reads `ansible.cfg` from the current directory, never from the playbook's, and this one sets the inventory — run `ansible-playbook ansible/site.yml` from the repo root and the inventory is never loaded, so `hosts: workstation` matches nothing and the play is skipped with no error.

## Choosing components interactively

`./bootstrap.sh` shows a checklist of everything the playbook can install, pre-ticked with the current defaults. Untick what you don't want, confirm, and it runs with just those. This is the default; `-s` skips it and installs the defaults straight through.

Re-running starts from your **previous** answers rather than the project defaults, so changing one thing doesn't mean re-ticking eleven others. Only keys actually present in the saved file are applied — a component added to the playbook since you last chose keeps its default instead of being silently dropped.

The list is **generated from the `install_*` toggles in `group_vars/all.yml`**, not from a copy kept in the script — a toggle appears in the menu if it carries a `## label` marker on the same line:

```yaml
install_docker: true              ## Docker CE + compose & buildx plugins
```

So adding a component to the playbook adds it to the menu. Adding one *without* a `## label` is the only way to get a toggle that the menu can't reach, which is occasionally what you want.

It uses `whiptail` (already present on Debian/Ubuntu — debconf depends on it) and falls back to a plain numbered toggle list if it's missing.

Two things keep the default-on menu from breaking unattended use: `-y` turns it off along with the run confirmation, and with no terminal on stdin — a pipe, cron, CI — it's skipped automatically and the defaults apply.

The answers are written to `selection.local.yml` beside the playbook and passed with `-e`, which outranks `group_vars`. That file is the point: the second run needs no menu at all.

```bash
ansible-playbook site.yml -e @selection.local.yml
```

Keep per-machine variants, edit it by hand, or delete it to fall back to the defaults. It's gitignored — `group_vars/all.yml` holds the project's defaults, `selection.local.yml` holds one machine's choices.

## Selective runs

Tags: `docker`, `kvm`, `devpod`, `brave`, `chrome`, `vscode`, `codium`, `git`, `gh`, `btop`, `appimage`, `ai`, `claude`, `opencode`, `herdr`, `tailscale`, plus groups `base`, `browsers`, `editors`, `network`.

```bash
ansible-playbook site.yml --tags docker,kvm
ansible-playbook site.yml --skip-tags ai
```

Toggles and defaults live in `group_vars/all.yml`; override per-run with `-e`:

```bash
ansible-playbook site.yml -e install_chrome=false
ansible-playbook site.yml -e claude_code_install_method=apt
```

## Notes

- **Repos are deb822 `.sources`**, not legacy `.list`. Chrome and VS Code packages try to re-register their own `.list` file; the playbook opts out via `/etc/default/*` and deletes any duplicate that appears.
- **The password is never stored or forwarded.** `ansible.cfg` sets `become_ask_pass = True`, so a bare `ansible-playbook site.yml` asks for the sudo password itself — the standalone run is correct with no flags, rather than failing every task on `sudo: a password is required` with no hint that `-K` was the fix. `bootstrap.sh` neither suppresses nor pre-fills that prompt; the password is typed where it's used and goes nowhere else. How many times you type it follows from that:
  - **Nothing to install** (every run after the first): the script works out what's missing *before* escalating, so with the prerequisites present it needs no privileges at all. The playbook's prompt is the only one.
  - **Packages missing** (first run): the script's own `apt-get` prompts, and the playbook prompts again afterwards. Twice, deliberately.

  Reusing sudo's credential cache to collapse that second prompt **does not work anyway**, which is worth recording because it's the obvious thing to try. `sudo -v` does warm the cache, and `sudo -n true` immediately before launching Ansible confirms it — then Ansible still fails with `sudo: a password is required`. `tty_tickets` (on by default) binds the ticket to the terminal, and Ansible runs become from a subprocess with no pty, so sudo can't match the ticket. The only alternatives are holding the password somewhere for Ansible to read or relaxing `tty_tickets` system-wide, and neither is worth saving one prompt on a first run.
- **Privilege escalation adapts to the release.** Ubuntu 25.10+ puts sudo-rs behind `/usr/bin/sudo`; it ignores the custom prompt Ansible passes with `-p`, so Ansible never matches its own prompt and every task — including `Gathering Facts` — dies with *"Timed out waiting for become success or become password prompt"*. `ansible_become_exe` in `group_vars/all.yml` probes for classic sudo at `/usr/bin/sudo.ws` and falls back to plain `sudo` on 24.04 and earlier, where that path doesn't exist. The probe reads the **control** node's filesystem, which is the target only because the inventory is `localhost ansible_connection=local` — if you repoint it at remote hosts, set the value per-host in the inventory or pass `-e ansible_become_exe=...`.
- **`docker_add_user_to_group: true`** puts you in the `docker` group, which is effectively root on this host. Set it to `false` to keep Docker sudo-only.
- **Group changes need a new login session.** `newgrp docker` works for the current shell.
- **`docker_purge_distro_packages`** defaults to `false`. Set it to `true` only if you want `docker.io`/`podman-docker`/`containerd` removed first.
- **Claude Code** defaults to `native` (`~/.local/bin/claude`, self-updating) because that matches the existing install on this box. The `apt` method installs system-wide to `/usr/bin` and updates via `apt upgrade` — but `~/.local/bin` usually precedes `/usr/bin` in `PATH`, so remove the native install first (`rm -f ~/.local/bin/claude && rm -rf ~/.local/share/claude`) or you'll have two.
- **GitHub CLI comes from GitHub's repo, not the archive.** Ubuntu ships `gh` in universe, but frozen at the release it shipped with (2.46 on resolute) and never updated, and `gh` warns about being out of date once it drifts. Its install task is the one place using `state: latest` rather than `present`: on a machine that already has the archive build, `present` would consider the package satisfied and leave the stale version in place, so adding the repo would change nothing until the next unrelated `apt upgrade`. Both are the same package name, so the higher version simply wins — no pinning involved. The keyring goes to `/usr/share/keyrings/githubcli-archive-keyring.gpg`, the path GitHub's own instructions use, for the Signed-By reason described above; any legacy `github-cli.list` left by following those instructions by hand is removed.
- **FUSE 2** is what AppImages need to mount themselves; without it they exit on `dlopen(): error loading libfuse.so.2`. Nothing else pulls it in now that the archive has moved to FUSE 3. The package is `libfuse2t64` on Ubuntu 24.04+ and `libfuse2` before that (the 64-bit `time_t` rename); the playbook probes for the right one rather than guessing from the release number.
- **Herdr installs like Claude Code's `native` method** — `herdr.dev/install.sh` puts one binary in `~/.local/bin` and self-updates from then on (`herdr update`, `herdr channel set stable|preview`). It runs as your user, not root, and is guarded with `creates:` so it runs once; the installer checks a SHA-256 from the release manifest and covers both x86_64 and aarch64. No PATH task is needed — `~/.local/bin` is what Ubuntu's stock `~/.profile` already adds, and it's where `claude` lives too.
- **DevPod is a pinned binary, not a package.** Upstream ships no apt repo and no distro package, only a static CLI per GitHub release, so `devpod_version` in `group_vars/all.yml` names the version and the playbook compares it against `devpod version` before downloading — bump the var to upgrade, and it's a no-op otherwise. `latest` isn't accepted: the guard needs an exact string to compare, and without one every run would re-fetch 85 MB. Upstream publishes no installer script; the documented Linux install is a `curl … && sudo install -c -m 0755 devpod /usr/local/bin` one-liner, which is exactly what the `get_url` task is — same asset, same destination, same mode. The CLI doesn't self-update, so bumping the pin *is* the documented upgrade ("download the latest version again"). There's a desktop app too, but amd64-only, which would make it the one component that skips arm64 — the playbook installs the CLI and leaves the GUI to you (it's an AppImage now, upstream having dropped deb/rpm, so `install_appimage_support` already covers its fuse2 dependency). DevPod's default provider is Docker, which `install_docker` covers.
- **OpenCode's installer** appends to shell rc files itself; the playbook also ensures `~/.profile` has the PATH entry and guards the install with `creates:` so it runs once.
- **Read-only probes carry `check_mode: false`.** `--check` skips `command` tasks by default, and the first thing the playbook runs is `dpkg --print-architecture` — skipped, `deb_arch` comes out empty, and the architecture assert kills the dry run at the third task before it reports anything. The same skip made the FUSE 2 probe fall back to the wrong package name in `--check` output. Reading a value isn't a change, so those probes run in either mode.
- **Apt sources pin an architecture explicitly.** Without a pin, apt queries each third-party repo for every foreign architecture `dpkg` has enabled — `i386` is commonly enabled by Steam or Wine — and hard-fails on the index it doesn't find.
- **Claude Code and OpenCode install via upstream scripts** that detect the architecture themselves, so the `native` path needs nothing arch-specific from the playbook.
- **Tailscale installs and starts `tailscaled`, but does not join a tailnet.** Bare `tailscale up` blocks on an interactive browser login, which would hang an unattended run — connect afterwards with `sudo tailscale up`. To join during provisioning, pass a key on the command line rather than committing one: `ansible-playbook site.yml -e tailscale_authkey=tskey-auth-...` (add flags via `tailscale_up_args`, e.g. `--ssh --advertise-exit-node`). The task is skipped when the node is already `Running`, and runs `no_log` so the key stays out of the output.
- **Tailscale's repo URL contains the distro name and codename** (`stable/ubuntu/noble`), unlike the other repos here, which serve one URI for all releases. Derivatives report their own codename — Mint 22 *is* Ubuntu 24.04 but says `wilma` — and there is no repo for it, so on those set `tailscale_repo_distribution` / `tailscale_repo_suite` to the upstream release.
