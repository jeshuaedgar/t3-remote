# T3 remote development host

Ansible (run from your Mac) configures one Ubuntu 24.04 server for development through T3 Code. Only built-in Ansible modules are used; there are no roles or collections.

| File | What it does |
| --- | --- |
| `playbooks/01-system.yml` | Ubuntu packages, automatic security updates |
| `playbooks/02-account.yml` | `dev` user, reused authorized keys, passwordless sudo, lingering |
| `playbooks/03-docker.yml` | Docker Engine and Compose from Docker's apt repo |
| `playbooks/04-tailscale.yml` | Tailscale install and `dev` operator permission |
| `playbooks/05-git.yml` | Copies your Mac's Git name/email; GitHub HTTPS helper (no keys or tokens) |
| `playbooks/06-tools.yml` | Copies `mise.toml` and runs `scripts/install-user-tools.sh` as `dev` |
| `playbooks/07-browser.yml` | T3 browser sandbox (AppArmor profile, libraries) |
| `playbooks/08-t3-service.yml` | T3 as a user service on `127.0.0.1:3773` |
| `playbooks/09-private-ssh.yml` | Restricts SSH to Tailscale addresses (run separately, last) |

`playbook.yml` runs 01–08. Settings live in `vars.yml`; the host lives in `inventory.ini` (gitignored).

## Run

```sh
brew install ansible
cp inventory.example.ini inventory.ini   # set ansible_host and ansible_user
bash setup.sh                            # all of 01-08
bash setup.sh playbooks/05-git.yml --diff
```

`setup.sh` refuses to run unless every inventory host is a device on your Mac's tailnet. Add `--ask-become-pass` if your account needs a sudo password.

## New server

The tailnet guard blocks a first run, since Tailscale isn't installed yet. Run `ansible-playbook -i inventory.ini playbooks/04-tailscale.yml` directly against the public address, then `sudo tailscale up` on the server, switch `ansible_host` to its tailnet name, and use `setup.sh` from then on.

## Restrict SSH to the tailnet

With Ansible already connected over Tailscale:

```sh
bash setup.sh playbooks/09-private-ssh.yml
```

This binds sshd and Ubuntu's `ssh.socket` to the Tailscale addresses, disables password login, restarts SSH, and checks that a new connection works. Public-IP SSH stops working; if Tailscale fails on the server, recover through your provider's console. This is not a firewall for other services or Docker-published ports.

## Tools

Edit `mise.toml` to add or pin tools; stage 06 copies it to `~/.config/mise/config.toml`. The helper script installs mise tools, Vite+ (official installer), Codex, Claude Code, T3, Chromium for Playwright, MCP servers (shadcn, Context7, Playwright, Cloudflare), and global agent skills including OpenSpec. It runs on every apply and uses `latest`, so versions are not reproducible; pin versions per project. Follow progress with `tail -f ~/.local/state/t3-remote/setup.log`.

## Sign-ins (manual, as `dev`)

```sh
sudo tailscale up
claude
codex
copilot
gh auth login --hostname github.com --git-protocol ssh --web
codex mcp login cloudflare   # plus Claude's /mcp menu
opencode                     # then /connect
```

## T3

T3 listens on loopback only. Add `dev@t3` as an SSH environment in T3, or pair mobile with `t3 pair --tailscale` (pairing links are credentials). Check the service with `t3 service status`. Don't run a second T3 on the same home as the service.

## Limits

No backups, firewall, or project dependencies are configured, and nothing resets Docker volumes or caches.
