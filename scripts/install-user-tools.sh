#!/usr/bin/env bash
# Run as the development user, never root.
set -Eeuo pipefail
[[ $EUID -ne 0 ]] || { echo "Run as the development user." >&2; exit 1; }
mkdir -p "$HOME/.local/state/t3-remote"
exec > >(tee "$HOME/.local/state/t3-remote/setup.log") 2>&1
export CI=1 NO_COLOR=1 MISE_YES=1
trap 'echo "Setup failed at line $LINENO; see ~/.local/state/t3-remote/setup.log" >&2' ERR
cd "$HOME"
mkdir -p "$HOME/.local/bin" "$HOME/workspace"
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
if ! command -v mise >/dev/null 2>&1; then
  curl -fsSL https://mise.run | sh
fi
# Shims work in non-interactive login shells used by T3's SSH connection.
path_line='export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"'
touch "$HOME/.profile" "$HOME/.bashrc"
for file in "$HOME/.profile" "$HOME/.bashrc"; do
  if ! grep -Fqx "$path_line" "$file"; then
    # Put this before Ubuntu's early return for non-interactive Bash sessions.
    temp=$(mktemp)
    printf '%s\n' "$path_line" > "$temp"
    cat "$file" >> "$temp"
    cat "$temp" > "$file"
    rm -f "$temp"
  fi
done
# Bash reads .bash_profile instead of .profile if the former exists.
if [[ -f "$HOME/.bash_profile" ]] && ! grep -Fqx "$path_line" "$HOME/.bash_profile"; then
  printf '\n%s\n' "$path_line" >> "$HOME/.bash_profile"
fi
echo 'Installing mise-managed development tools...'
# Stage 06 copies the repository's mise.toml to the global config first.
mise install --yes
mise upgrade --yes
# Install first so migration from mise never leaves Codex unavailable.
echo 'Installing/updating standalone Codex...'
curl -fsSL https://chatgpt.com/codex/install.sh | sh
mise reshim
hash -r
echo 'Installing/updating Vite+...'
export PATH="$HOME/.vite-plus/bin:$PATH"
if command -v vp >/dev/null 2>&1; then
  vp upgrade
else
  curl -fsSL https://vite.plus | bash
fi
echo 'Installing/updating Claude Code...'
curl -fsSL https://claude.ai/install.sh | bash -s latest
echo 'Installing/updating T3 Code...'
if ! command -v t3 >/dev/null 2>&1; then
  curl -fsSL https://t3.codes/install.sh | sh
else
  t3 update --channel stable --yes
fi
echo 'Installing MCP servers and the headless Chromium browser...'
mise reshim
playwright install --with-deps chromium
# Resolve Chromium at launch so mise upgrades do not leave a versioned path behind.
cat > "$HOME/.local/bin/t3-playwright-mcp" <<'MCP_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
browser=$(node -e 'console.log(require(process.argv[1] + "/node_modules/playwright").chromium.executablePath())' "$(mise where npm:playwright)")
exec playwright-mcp --headless --isolated --executable-path "$browser" "$@"
MCP_WRAPPER
chmod 755 "$HOME/.local/bin/t3-playwright-mcp"
echo 'Configuring user MCP servers for Claude and Codex...'
python3 - <<'MCP_CONFIG'
import json, os, re
from pathlib import Path
p = Path.home() / '.claude.json'
config = json.loads(p.read_text()) if p.exists() else {}
servers = config.setdefault('mcpServers', {})
bin_dir = str(Path.home() / '.local/share/mise/shims')
servers.update({
    'shadcn': {'type': 'stdio', 'command': bin_dir + '/shadcn', 'args': ['mcp']},
    'context7': {'type': 'stdio', 'command': bin_dir + '/context7-mcp', 'args': []},
    'playwright': {'type': 'stdio', 'command': str(Path.home() / '.local/bin/t3-playwright-mcp'), 'args': []},
    'cloudflare': {'type': 'http', 'url': 'https://mcp.cloudflare.com/mcp'},
})
p.write_text(json.dumps(config, indent=2) + '\n')
os.chmod(p, 0o600)
# Write the HTTP endpoint directly: `codex mcp add --url` can start interactive
# OAuth, which must wait until the user signs in after unattended provisioning.
p = Path.home() / '.codex/config.toml'
p.parent.mkdir(parents=True, exist_ok=True)
text = p.read_text() if p.exists() else ''
section = re.search(r'^\[mcp_servers\.cloudflare\][^\n]*\n(?:(?!\[).*(?:\n|$))*', text, re.M)
url = 'url = "https://mcp.cloudflare.com/mcp"\n'
if section:
    body = section.group()
    if re.search(r'^url\s*=', body, re.M):
        body = re.sub(r'^url\s*=.*(?:\n|$)', url, body, count=1, flags=re.M)
    else:
        body = body.rstrip('\n') + '\n' + url
    text = text[:section.start()] + body + text[section.end():]
else:
    text = text.rstrip('\n') + '\n\n[mcp_servers.cloudflare]\n' + url
p.write_text(text)
os.chmod(p, 0o600)
MCP_CONFIG
codex mcp add shadcn -- "$HOME/.local/share/mise/shims/shadcn" mcp
codex mcp add context7 -- "$HOME/.local/share/mise/shims/context7-mcp"
codex mcp add playwright -- "$HOME/.local/bin/t3-playwright-mcp"
echo 'Installing global skills for Claude and Codex...'
npx -y skills@latest add https://github.com/mattpocock/skills \
  --skill grill-with-docs grilling domain-modeling --global --agent claude-code codex --yes
npx -y skills@latest add jeshuaedgar/skills \
  --skill '*' --global --agent claude-code codex --yes
# OpenSpec 1.14 has no init -g. Generate with its own CLI in a dedicated
# staging project, then publish only its generated skills/commands globally.
openspec_stage="$HOME/.local/share/t3-remote/openspec-skills"
mkdir -p "$openspec_stage"
openspec init "$openspec_stage" --tools claude,codex --no-animation --no-copilot-cloud
python3 - <<'OPENSPEC_GLOBAL'
import shutil
from pathlib import Path
home = Path.home()
stage = home / '.local/share/t3-remote/openspec-skills'
for source, target in [
    (stage / '.agents/skills', home / '.agents/skills'),
    (stage / '.claude/skills', home / '.claude/skills'),
]:
    target.mkdir(parents=True, exist_ok=True)
    for skill in source.glob('openspec-*'):
        if skill.is_dir():
            shutil.copytree(skill, target / skill.name, dirs_exist_ok=True)
commands = stage / '.claude/commands/opsx'
if commands.is_dir():
    shutil.copytree(commands, home / '.claude/commands/opsx', dirs_exist_ok=True)
print('OpenSpec generated skills installed globally for Claude and Codex.')
OPENSPEC_GLOBAL
mise ls --current
