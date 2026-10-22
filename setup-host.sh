#!/usr/bin/env bash
# setup-host.sh - privileged host preparation for the NemoClaw stack.
#
#   sudo ./setup-host.sh          apply
#   sudo ./setup-host.sh --check  report only, change nothing
#
# Idempotent and non-destructive: it deletes nothing, backs up any file it
# rewrites, and leaves /var/lib/docker in place after migrating it.

set -euo pipefail

TARGET_USER="${SUDO_USER:-jack}"
DOCKER_ROOT="/home/docker"
OLLAMA_MODELS="/home/ollama-models"
CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
info() { printf '\033[1;34m[info]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
run()  { if (( CHECK_ONLY )); then printf '   would run: %s\n' "$*"; else "$@"; fi; }

(( EUID == 0 )) || die "must run as root: sudo $0 ${1:-}"
id "$TARGET_USER" &>/dev/null || die "target user '$TARGET_USER' does not exist"

# ---------------------------------------------------------------- preflight
step "Preflight"
command -v nvidia-smi &>/dev/null || die "nvidia-smi not found - install the NVIDIA driver first"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | sed 's/^/   GPU: /'
grep -q 'landlock' /sys/kernel/security/lsm \
  && ok "Landlock active - OpenShell filesystem enforcement will apply" \
  || warn "Landlock NOT in the active LSM list; OpenShell will degrade to best_effort"
node_v="$(command -v node &>/dev/null && node --version || echo none)"
[[ "$node_v" != none ]] || die "Node.js not found; NemoClaw needs >= 22.19.0"
ok "Node $node_v (installer requires >= 22.19.0)"
avail_home="$(df -BG --output=avail /home | tail -1 | tr -dc '0-9')"
(( avail_home >= 40 )) && ok "/home has ${avail_home}G free" \
  || warn "/home has only ${avail_home}G free; NemoClaw recommends 40G"

# ------------------------------------------------------------- 1. packages
step "1. Packages"
need_pkgs=()
for p in nvidia-container-toolkit ollama-cuda; do
  pacman -Qq "$p" &>/dev/null && ok "$p already installed" || need_pkgs+=("$p")
done
if (( ${#need_pkgs[@]} )); then
  info "installing: ${need_pkgs[*]}"
  run pacman -S --needed --noconfirm "${need_pkgs[@]}"
fi

# --------------------------------------------------------- 2. docker group
step "2. Docker group"
if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker; then
  ok "$TARGET_USER already in the docker group"
else
  run usermod -aG docker "$TARGET_USER"
  warn "group membership only loads at login: run 'newgrp docker' or re-login"
fi

# ------------------------------------------- 3. docker data-root + CDI
step "3. Docker data-root -> $DOCKER_ROOT (and CDI)"
current_root="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo unknown)"
info "current Docker root: $current_root"

desired='{"data-root":"'"$DOCKER_ROOT"'","features":{"cdi":true},"cdi-spec-dirs":["/etc/cdi","/var/run/cdi"]}'

if [[ "$current_root" == "$DOCKER_ROOT" ]]; then
  ok "data-root already $DOCKER_ROOT"
else
  info "stopping docker to migrate its state"
  run systemctl stop docker.socket docker.service
  run install -d -m 0711 "$DOCKER_ROOT"
  if [[ -d /var/lib/docker && -n "$(ls -A /var/lib/docker 2>/dev/null)" ]]; then
    info "copying /var/lib/docker -> $DOCKER_ROOT (original left intact)"
    run rsync -aHAX --info=progress2 /var/lib/docker/ "$DOCKER_ROOT"/
  else
    info "/var/lib/docker is empty; nothing to copy"
  fi
fi

if [[ -f /etc/docker/daemon.json ]]; then
  if (( CHECK_ONLY )); then
    printf '   would merge into existing /etc/docker/daemon.json: %s\n' "$desired"
  else
    cp -a /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%s)"
    tmp="$(mktemp)"
    jq -s '.[0] * .[1]' /etc/docker/daemon.json <(printf '%s' "$desired") > "$tmp"
    mv "$tmp" /etc/docker/daemon.json
    ok "merged into /etc/docker/daemon.json (backup kept)"
  fi
else
  run install -d -m 0755 /etc/docker
  if (( CHECK_ONLY )); then
    printf '   would create /etc/docker/daemon.json: %s\n' "$desired"
  else
    printf '%s' "$desired" | jq . > /etc/docker/daemon.json
    ok "wrote /etc/docker/daemon.json"
  fi
fi
run systemctl start docker.service

# --------------------------------------------------------- 4. CDI spec
step "4. NVIDIA CDI spec"
# OpenShell requests GPUs as nvidia.com/gpu CDI devices. Arch has no
# nvidia-cdi-refresh.service, so the spec is generated here and must be
# regenerated after every driver upgrade.
run install -d -m 0755 /etc/cdi
if (( CHECK_ONLY )); then
  printf '   would run: nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml\n'
elif command -v nvidia-ctk &>/dev/null; then
  nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
  nvidia-ctk cdi list | sed 's/^/   /'
  ok "CDI spec written to /etc/cdi/nvidia.yaml"
else
  warn "nvidia-ctk missing (package step skipped?) - rerun after install"
fi
# Legacy runtime shim as a fallback; harmless alongside CDI.
command -v nvidia-ctk &>/dev/null && run nvidia-ctk runtime configure --runtime=docker --set-as-default=false || true
run systemctl restart docker.service

# -------------------------------------------------------- 5. ollama tuning
step "5. Ollama model store and KV-cache tuning"
ollama_user="$(systemctl show -p User --value ollama.service 2>/dev/null || true)"
[[ -n "$ollama_user" ]] || ollama_user=ollama
info "ollama.service runs as: $ollama_user"
if id "$ollama_user" &>/dev/null; then
  run install -d -o "$ollama_user" -g "$ollama_user" -m 0755 "$OLLAMA_MODELS"
else
  warn "user '$ollama_user' not found yet; creating dir unowned"
  run install -d -m 0755 "$OLLAMA_MODELS"
fi

# Arch ships ollama.service with ProtectHome=yes, which replaces /home with an
# empty tmpfs inside the service namespace - so OLLAMA_MODELS cannot point at
# /home directly. Rather than weaken that hardening on a network-facing daemon,
# bind-mount the big-disk directory to a path under /var/lib, which the unit can
# see (ProtectSystem=full leaves /var writable).
MODELS_MOUNT="/var/lib/ollama/models"
if id "$ollama_user" &>/dev/null; then
  run install -d -o "$ollama_user" -g "$ollama_user" -m 0755 "$MODELS_MOUNT"
else
  run install -d -m 0755 "$MODELS_MOUNT"
fi

fstab_line="$OLLAMA_MODELS $MODELS_MOUNT none bind 0 0"
if grep -qsF "$MODELS_MOUNT" /etc/fstab; then
  ok "fstab already has a bind entry for $MODELS_MOUNT"
elif (( CHECK_ONLY )); then
  printf '   would append to /etc/fstab: %s\n' "$fstab_line"
else
  cp -a /etc/fstab "/etc/fstab.bak.$(date +%s)"
  printf '\n# NemoClaw: keep Ollama model weights on the large /home filesystem\n%s\n' "$fstab_line" >> /etc/fstab
  ok "appended bind mount to /etc/fstab (backup kept)"
fi
run systemctl daemon-reload
if ! mountpoint -q "$MODELS_MOUNT" 2>/dev/null; then
  run mount "$MODELS_MOUNT"
fi
mountpoint -q "$MODELS_MOUNT" 2>/dev/null && ok "$OLLAMA_MODELS mounted at $MODELS_MOUNT" \
  || { (( CHECK_ONLY )) || warn "bind mount not active at $MODELS_MOUNT"; }

# OLLAMA_HOST is deliberately NOT set here: NemoClaw pins Ollama to
# 127.0.0.1:11434 itself and fronts it with a token-gated proxy on 11435.
# Setting it here would be overwritten or fight the installer.
# KV quantization only takes effect when flash attention is enabled.
run install -d -m 0755 /etc/systemd/system/ollama.service.d
if (( CHECK_ONLY )); then
  printf '   would write /etc/systemd/system/ollama.service.d/override.conf\n'
else
  cat > /etc/systemd/system/ollama.service.d/override.conf <<EOF
[Service]
Environment="OLLAMA_MODELS=$MODELS_MOUNT"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
EOF
  ok "wrote ollama override.conf"
fi
run systemctl daemon-reload
run systemctl restart ollama.service || run systemctl enable --now ollama.service

# ------------------------------------------------------------- 6. report
step "Result"
if (( CHECK_ONLY )); then
  info "--check mode: nothing was changed"
  exit 0
fi
docker info -f 'Docker root: {{.DockerRootDir}}' 2>/dev/null || warn "docker not responding"
systemctl is-active ollama.service >/dev/null && ok "ollama.service active" || warn "ollama.service not active"
printf '\n'
ok "Host prepared. Next, as $TARGET_USER (not root):"
cat <<EOF
   newgrp docker                 # or re-login, to pick up group membership
   docker run --rm --device nvidia.com/gpu=all \\
     nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi    # prove GPU-in-container
EOF
