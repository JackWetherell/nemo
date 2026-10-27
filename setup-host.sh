#!/usr/bin/env bash
# setup-host.sh - host preflight for the NemoClaw + Hermes stack.
#
#   ./setup-host.sh           check everything, report
#   ./setup-host.sh --fix     also repair the permission bits it can (no sudo)
#
# This stack uses a remote model, so there is no GPU, Ollama or bind mount to
# configure. Anything needing sudo is printed, not run.

set -uo pipefail
FIX=0; [[ "${1:-}" == "--fix" ]] && FIX=1

ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*"; FAILED=1; }
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
FAILED=0

step "Container runtime"
if [[ "$(systemctl is-active docker 2>/dev/null)" == active ]]; then
  ok "docker active (root: $(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo '?'))"
  id -nG | tr ' ' '\n' | grep -qx docker || warn "you are not in the docker group: sudo usermod -aG docker $USER"
else
  bad "docker not running:  sudo systemctl enable --now docker"
fi

step "Node"
if command -v node >/dev/null 2>&1; then
  v="$(node --version | tr -d v)"; maj="${v%%.}"; maj="${v%%.*}"; min="$(cut -d. -f2 <<<"$v")"
  if (( maj > 22 || (maj == 22 && min >= 19) )); then ok "node v$v (needs >= 22.19)"
  else bad "node v$v is too old; NemoClaw needs >= 22.19"; fi
else
  bad "node not found; NemoClaw needs >= 22.19"
fi

step "Kernel isolation"
grep -q landlock /sys/kernel/security/lsm 2>/dev/null \
  && ok "Landlock active - OpenShell enforcement will apply" \
  || warn "Landlock NOT in the live LSM list; OpenShell degrades to best_effort"
[[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" == cgroup2fs ]] && ok "cgroup v2" || warn "cgroup v2 not detected"

step "Required tools"
missing=()
for t in zstd strings lsof jq curl git sha256sum; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
if ((${#missing[@]})); then bad "missing: ${missing[*]}  (strings is in binutils)"; else ok "zstd binutils lsof jq curl git present"; fi

step "Permission chain for the OpenShell state directory"
# OpenShell validates every ancestor of ~/.local/state and refuses to start if
# any has a group OR world write bit. `chmod o-w` alone is not enough.
offenders=()
for d in /home "$HOME" "$HOME/.local" "$HOME/.local/state"; do
  [[ -e "$d" ]] || continue
  [[ -n "$(find "$d" -maxdepth 0 \( -perm -0020 -o -perm -0002 \) 2>/dev/null)" ]] && offenders+=("$d")
done
if ((${#offenders[@]})); then
  if (( FIX )); then
    for d in "${offenders[@]}"; do
      if [[ -w "$d" && "$(stat -c %U "$d")" == "$USER" ]]; then chmod go-w "$d" && ok "fixed $d"
      else bad "$d needs root:  sudo chmod go-w $d"; fi
    done
  else
    for d in "${offenders[@]}"; do bad "$d is group- or world-writable (rerun with --fix, or chmod go-w)"; done
  fi
else
  ok "chain clean: $(stat -c '%A' "$HOME/.local/state" 2>/dev/null) ~/.local/state"
fi

step "Disk"
avail="$(df -BG --output=avail /home 2>/dev/null | tail -1 | tr -dc '0-9')"
(( avail >= 40 )) && ok "/home has ${avail}G free" || warn "/home has ${avail}G free; NemoClaw recommends 40G"

step "Result"
if (( FAILED )); then
  warn "preflight found problems - fix the [fail] lines above before installing"
  exit 1
fi
ok "host is ready for:  bash /tmp/nemoclaw.sh"
