# CLAUDE.md - ANS-DevMachine-Linux

Guidance for Claude Code when working in this project.

## Project Overview

Ansible provisioning for an Ubuntu developer workstation — Docker, KVM,
browsers, editors and AI CLIs from a single playbook. Ubuntu 24.04–26.04,
amd64 or arm64. `bootstrap.sh` is the entry point; `ansible/site.yml` is the
whole playbook.

## Conventions

- **The playbook must be run from `ansible/`.** Ansible reads `ansible.cfg`
  from the current directory only, and `ansible/ansible.cfg` is what supplies
  `inventory = inventory.ini`. `ansible-playbook ansible/site.yml` from the repo
  root loads no inventory, so `hosts: workstation` matches nothing and the run
  **exits 0 having provisioned nothing**. The correct command is
  `cd ansible && ansible-playbook site.yml`. `bootstrap.sh:339` `cd`s for this
  reason — do not remove that.
- **One play, no roles.** Everything is in `ansible/site.yml`, in commented
  per-component blocks. Keep that layout; a role split is not wanted here.
- **`ansible.builtin` only.** No Galaxy collections, no lockfile — deliberate.
- **Variables live in `ansible/group_vars/all.yml`.** Project defaults only.
  Per-machine choices go in `ansible/selection.local.yml` (gitignored, written
  by `bootstrap.sh`, passed with `-e`).
- **`## label` markers are load-bearing.** `bootstrap.sh` parses
  `install_*: true  ## Label` lines out of `all.yml` to build its checklist.
  Reformatting those lines removes components from the menu.
- **Every `command`/`shell` task carries `changed_when: false`, a guarded
  `changed_when`, or `creates:`.** New ones must too.
- **Repos are deb822 `.sources` with an explicit `architectures:` pin**, keyed
  off `deb_arch` from `dpkg --print-architecture` (never `ansible_architecture`).
  Cleanup tasks may only delete `.list` files — naming a `.sources` file would
  delete the repo the playbook just wrote.
- **`target_user` and `ansible_become_exe` resolve on the control node**, correct
  only because the inventory is `localhost ansible_connection=local`; repointing
  it at remote hosts requires overriding both per-host.
- Never run the playbook to test a change — it mutates the machine. `--check
  --diff` from `ansible/` is the safe check.

## Dependencies

- `ansible-core` 2.15+ — floor set by `deb822_repository`; `bootstrap.sh`
  installs it and warns below 2.15.
- `bash`, `sudo`, `apt-get` on the target; `whiptail` optional (the menu falls
  back to a plain numbered list).
- Third-party apt repos and the Claude Code / OpenCode installers are
  intentionally unpinned: a workstation should track current.
