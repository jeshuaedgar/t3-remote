#!/usr/bin/env bash
# Run from your Mac: bash setup.sh [playbooks/NN-name.yml] [ansible options]
set -Eeuo pipefail
cd "$(dirname "$0")"
command -v ansible-playbook >/dev/null || { echo 'Install Ansible: brew install ansible' >&2; exit 1; }
[[ -f inventory.ini ]] || { echo 'Copy inventory.example.ini to inventory.ini first.' >&2; exit 1; }
# Deploy only to tailnet devices: tailscale resolves peers and rejects anything else.
for host in $(ansible-inventory -i inventory.ini --list |
  python3 -c 'import json,sys; [print(v.get("ansible_host", k)) for k, v in json.load(sys.stdin)["_meta"]["hostvars"].items()]'); do
  tailscale ip -4 "$host" >/dev/null || { echo "$host is not on your tailnet." >&2; exit 1; }
done
playbook=playbook.yml
if [[ ${1:-} == *.yml ]]; then playbook=$1; shift; fi
exec ansible-playbook -i inventory.ini "$playbook" "$@"
