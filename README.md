# NemoClaw on a 4090

An always-on local AI agent: **OpenClaw** as the harness, **NVIDIA OpenShell** as the
execution boundary, **Qwen3.8-27B** as the model, served by Ollama on a single
RTX 4090. **NemoClaw** is NVIDIA's reference stack that wires the three together.

Nothing leaves the machine. The model runs locally; the agent runs as an
unprivileged, network-denied process that cannot reach the model, the filesystem,
or the internet except through a policy check.

---

## The stack

| Layer | Project | Role here |
|---|---|---|
| Orchestrator | [NVIDIA/NemoClaw](https://github.com/NVIDIA/NemoClaw) (Apache 2.0) | Installs and manages the stack. Applies a versioned *blueprint* — resolve artifact → verify digest → plan resources → apply via the OpenShell CLI |
| Execution boundary | [NVIDIA/OpenShell](https://github.com/NVIDIA/OpenShell) | Sandboxes the agent, holds credentials, mediates every network call |
| Harness | OpenClaw (MIT) | The agent itself: sessions, skills, tool-calling loop, messaging channels |
| Model | [Qwen/Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B) (Apache 2.0) | 27.8B hybrid-attention VLM, 262k context, served via Ollama |

NVIDIA's reference deployment runs **Nemotron 3 Super 120B on a DGX Spark**
(GB10, ~128 GB unified memory). That is impossible on 24 GB, so this build
substitutes Qwen3.8-27B — see [Why this model](#why-this-model-on-24-gb) for why
that substitution is what makes the stack fit, rather than a mere downgrade.

---

## How it fits together

```
  you ──► openclaw tui / web UI :18789
                  │
    ┌─────────────┼──────────────── host (trusted) ─────────────────┐
    │             ▼                                                 │
    │   ┌──────────────────┐        ┌──────────────────┐            │
    │   │ OpenShell        │        │ Ollama           │            │
    │   │ Gateway          │        │ 127.0.0.1:11434  │            │
    │   │ policy, creds,   │        │ qwen38-27b-64k   │            │
    │   │ JWT, lifecycle   │        └────────▲─────────┘            │
    │   └────────┬─────────┘                 │ token-gated proxy    │
    │            │ policy                    │ :11435               │
    │   ┌────────▼─────────┐                 │                      │
    │   │ Supervisor       │─────────────────┘                      │
    │   │ TRUSTED: decides, holds credentials, resolves DNS,        │
    │   │ opens the only sanctioned connections                     │
    │   └────────▲─────────┘                                        │
    └────────────┼───── protected channel (sole egress) ────────────┘
                 │
    ┌────────────▼──────────── sandbox (untrusted) ─────────────────┐
    │   OpenClaw agent                                              │
    │     · runs as user `sandbox`, no Linux capabilities           │
    │     · Landlock confines the filesystem                        │
    │     · seccomp user-notification stages every syscall          │
    │     · default-deny network: no route out except the channel   │
    │     · reaches the model only as http://inference.local        │
    └───────────────────────────────────────────────────────────────┘
```

The agent never holds a credential and never opens a socket. When it tries, the
sandbox intercepts the connect/DNS call, identifies the calling program, and
relays the request to the **supervisor**, which checks policy, attaches any
credential the policy permits, and opens the real connection itself. The
sandbox makes no policy decisions — it shares a boundary with untrusted code,
so it is not trusted to.

Inference takes the same path:

```
agent → inference.local → OpenShell route → proxy :11435 → Ollama :11434
```

The agent cannot see the model endpoint, so a prompt-injected agent cannot
exfiltrate through it or reconfigure it.

---

## Why this model on 24 GB

Qwen3.8-27B is **hybrid-attention**. Its 64 layers are
`16 × (3 × Gated DeltaNet → 1 × Gated Attention)`, so only **16 layers carry a
growing KV cache**; the other 48 hold constant-size recurrent state.

With 4 KV heads × 256 head_dim, the cache costs:

```
2 (K,V) × 4 heads × 256 dim × 16 layers = 32,768 elem/token = 64 KiB/token @ BF16
```

So 64k context needs **4.0 GiB** — not the ~16 GiB a conventional dense 27B
would need (all 64 layers caching → 256 KiB/token). `OLLAMA_KV_CACHE_TYPE=q8_0`
halves it again to ~2.0 GiB, at a measured perplexity cost of 0.002–0.05.

Measured on this machine (`nvidia-smi` with the model resident, not estimated):

| Item | Size |
|---|---|
| Q4_K_M weights | ~16.0 GiB |
| CLIP vision projector (460.7M params) | ~0.9 GiB |
| q8_0 KV cache @ 64k | ~2.0 GiB |
| Compute buffers + CUDA context | ~1.2 GiB |
| Desktop (Xorg + kwin_x11) | ~1.2 GiB |
| **Total** | **21786 MiB of 24564 MiB** |

`ollama ps` reports **100% GPU** — nothing spills to host RAM, which is what
would otherwise destroy throughput.

That leaves **~2.7 GiB headroom**, and it is not spare: Qwen3.8-27B is
multimodal, so image or video input draws on it. If you feed it large images and
see a spill, drop `num_ctx` to 48000 to buy back ~0.5 GiB.

**The architecture is load-bearing.** A same-size full-attention model could not
hold a 64k agent context on this card at all.

---

## Setup

Prerequisites assumed: NVIDIA driver, Docker, Node ≥ 22.19, and ~40 GB free disk.

### 1. Host preparation (privileged)

```bash
sudo ./setup-host.sh --check    # dry run, changes nothing
sudo ./setup-host.sh            # apply
newgrp docker                   # or re-login
```

Installs `nvidia-container-toolkit` + `ollama-cuda`, adds you to `docker`,
relocates Docker's data-root to `/home/docker`, generates the NVIDIA CDI spec,
bind-mounts the model store, and writes the Ollama tuning override. It is
idempotent, backs up every file it rewrites, and deletes nothing.

**Why the model store is bind-mounted.** Arch ships `ollama.service` with
`ProtectHome=yes`, so systemd replaces `/home` with an empty tmpfs inside the
service's mount namespace — pointing `OLLAMA_MODELS` at `/home/...` fails with
`mkdir: permission denied` no matter how the directory is owned. Rather than
weaken that hardening on a network-facing daemon, the weights stay on `/home`
and are bind-mounted to `/var/lib/ollama/models`, which the unit can see
(`ProtectSystem=full` leaves `/var` writable):

```
/home/ollama-models  /var/lib/ollama/models  none  bind  0 0   # /etc/fstab
```

Verify GPU-in-container works — this is the step most likely to be wrong:

```bash
docker run --rm --device nvidia.com/gpu=all \
  nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi
```

### 2. Model

```bash
ollama pull qwen3.8:27b                      # ~17 GB
ollama create qwen38-27b-64k -f Modelfile    # pins num_ctx=64000 + sampling
ollama show qwen38-27b-64k
```

The `Modelfile` is not optional: Ollama's default `num_ctx` is **4096**, and the
KV cache is allocated for the full `num_ctx` up front.

### 3. NemoClaw

Review the installer before running it, rather than piping it to a shell:

```bash
curl -fsSL https://www.nvidia.com/nemoclaw.sh -o /tmp/nemoclaw.sh
less /tmp/nemoclaw.sh
```

It is a thin bootstrap: it clones `NVIDIA/NemoClaw` at a ref and executes
`scripts/install.sh` from that clone. Pin the ref for reproducibility — but pin
the **release tag, not a commit SHA**. Sandbox workload preparation compares the
install ref against the installed build identity (`v0.0.137`), and a bare SHA
fails that check with *"the exact install ref does not match the installed build
identity"* even when it names the very same commit:

```bash
NEMOCLAW_INSTALL_REF=v0.0.137 \
NEMOCLAW_DISABLE_TELEMETRY=1 \
NEMOCLAW_AGENT=openclaw \
NEMOCLAW_PROVIDER=ollama \
NEMOCLAW_MODEL=qwen38-27b-64k \
NEMOCLAW_POLICY_MODE=suggested \
NEMOCLAW_WEB_SEARCH_PROVIDER=none \
NEMOCLAW_SANDBOX_NAME=queeg \
bash /tmp/nemoclaw.sh
```

Run it **in a real terminal** — the installer needs a TTY to authenticate `sudo`
(it probes `sudo -n`, then falls back to `sudo -v` via `/dev/tty`).

Note that `NEMOCLAW_SANDBOX_NAME` is honoured only in non-interactive mode; the
interactive wizard generates its own name, so set it at the "Edit sandbox name"
prompt instead. The name is just an identifier for the `nemoclaw <name> …` and
`openshell forward … <name>` commands.

Telemetry is on by default; `NEMOCLAW_DISABLE_TELEMETRY=1` opts out.

### 4. Inference route

Onboarding normally wires this. To set or repair it by hand:

```bash
openshell provider create --name ollama --type openai \
  --credential OPENAI_API_KEY=empty \
  --config OPENAI_BASE_URL=http://host.openshell.internal:11434/v1
openshell inference set --provider ollama --model qwen38-27b-64k
nemoclaw inference get
```

`host.openshell.internal` is how the sandbox addresses the host.

---

## Usage

`openclaw` itself is **not installed on the host** — it exists only inside the
sandbox. You drive everything through `nemoclaw`.

### Shell shortcuts (`~/.bashrc`)

| Command | Kind | What it does |
|---|---|---|
| `ncl` | alias | `nemoclaw launch queeg`: TUI, and (re)starts the Ollama auth proxy |
| `ncl_mount` / `ncl_umount` | alias | SSHFS-mount the workspace at `~/queeg` (see [Shared workspace](#shared-workspace-queeg)) |
| `ncl_sh [-u 0]` | function | `docker exec` shell in the container as `sandbox` (or root) |
| `ncl_stop` | function | Emergency stop: kill auth proxy → stop sandbox → unload model → unmount `~/queeg` |
| `ncl_list` | function | List all `ncl*` commands |

`ncl_sh` lands in the container's network namespace, **not** the agent's nested
one, so network tests from it (and `openclaw doctor`'s gateway check) do not
reflect what the agent sees. To test the agent's real egress path:

```bash
C=$(docker ps -q --filter name=openshell-default--queeg-)
GP=$(docker exec $C pgrep -f openclaw-gateway | head -1)
docker exec -u 0 $C nsenter -t $GP -n -- env HTTPS_PROXY=http://10.200.0.1:3128 \
  curl -s -o /dev/null -w '%{http_code}\n' --cacert /etc/openshell-tls/ca-bundle.pem https://pypi.org/simple/
```

The `--cacert` matters: L7-inspected presets (e.g. `pypi`) re-sign TLS with the
OpenShell CA, so without it curl reports `000` even when the request is allowed.

`ps -eo pid,ppid,user,etime,cmd --forest` inside the container shows the tree:
`openshell-sandbox` (PID 1, supervisor) → `nemoclaw-start` → `openclaw-gateway`
(the agent; tool calls appear as its children), plus `openclaw tui` per session.

### Talk to it

```bash
nemoclaw launch queeg                    # interactive TUI (the main way in)
nemoclaw queeg dashboard-url --quiet     # authenticated browser URL (token embedded)

# one-shot, scriptable
nemoclaw queeg agent --agent main --message "summarise the file I uploaded"
```

Open the dashboard URL in a **new tab**. Editing the `#token=` fragment of an
already-open tab does not reload the page, so the UI never reads the token and
hangs on the WebSocket.

### Lifecycle

```bash
nemoclaw list                            # all sandboxes
nemoclaw queeg status                    # health, route, GPU, policy
nemoclaw queeg doctor                    # deep diagnosis (add --fix to apply)
nemoclaw queeg logs --follow             # live logs, incl. OCSF audit events
nemoclaw queeg stop | start              # preserves workspace state
nemoclaw queeg gateway restart           # after config changes
nemoclaw queeg rebuild                   # upgrade to current agent version
```

### Getting data in and out

The sandbox cannot see your home directory, so files must be handed over
explicitly:

```bash
nemoclaw queeg upload ./report.csv       # host -> sandbox
nemoclaw queeg download /sandbox/out.md  # sandbox -> host
nemoclaw queeg exec -- ls -la /sandbox   # run a command inside
nemoclaw queeg connect                   # interactive shell inside
```

### Shared workspace (`~/queeg`)

```bash
sudo pacman -S sshfs     # once
ncl_mount                # nemoclaw queeg share mount /sandbox/.openclaw/workspace ~/queeg
ncl_umount
```

SSHFS logs in as `sandbox`, so files show as uid 998 but you can read and write
them, and files you create are owned correctly for the agent. The sandbox must
be running. This is one-way visibility: you see the agent's files; it still
cannot see yours. If unmount says *Device or resource busy*, a shell is `cd`'d
into it — `cd ~`, or `fusermount3 -uz ~/queeg`.

Workspace layout (`/sandbox/.openclaw/workspace`):

| Path | Loaded into every prompt? | Role |
|---|---|---|
| `AGENTS.md` | yes | Operating rules (also the only file sub-agents get) |
| `SOUL.md`, `IDENTITY.md` | yes | Persona, name |
| `USER.md` | yes, **capped at 4,000 chars** | Model of you; the excess is silently dropped |
| `MEMORY.md` | yes (main session only) | Curated long-term memory; dreaming promotes into it |
| `memory/YYYY-MM-DD.md` | no — via `memory_search`/`memory_get` (and once after `/new`) | Daily logs |
| `memory/.dreams/`, `memory/dreaming/`, `DREAMS.md` | no | Dreaming (memory consolidation) state, reports, diary |
| `POLICY.md` | no | Snapshot written by `nemoclaw … policy explain`; goes stale on preset changes |
| `notes/` | no | Agent's own files |

Limits: 20,000 chars per bootstrap file, 60,000 total. `/context detail` in the
TUI shows what is actually injected.

### Git workflow

The `github` preset allows only `/usr/bin/git` to `github.com`/`api.github.com:443`
(`access: full`, so no credential injection; `gh` is not in the image; no SSH).
NemoClaw has no GitHub provider for in-sandbox credentials. Current choice:
**the agent commits locally, you push from the host.** This is stated in
`AGENTS.md` so the agent doesn't try to push and then route around the failure.
On the host, mark the SSHFS repos as safe (they are owned by uid 998):

```bash
git config --global --add safe.directory '/home/jack/queeg/*'   # git >= 2.46
```

If autonomous push is ever wanted: a fine-grained PAT scoped to specific repos,
stored via git's credential helper on the volume (not an env var). The agent can
read it — accept that knowingly.

### Inference

```bash
nemoclaw inference get
nemoclaw inference set --model <model> --provider <provider> --sandbox queeg
ollama ps                                # is the model resident? 100% GPU?
ollama stop qwen38-27b-64k               # free 21.8 GB of VRAM on demand
```

### Secrets

```bash
nemoclaw queeg exec -- openclaw secrets audit --check      # expect plaintext=0
nemoclaw queeg exec --tty -- openclaw secrets configure    # map config -> SecretRef
nemoclaw queeg exec -- openclaw secrets reload             # apply without restart
```

Seed the store *before* mapping a ref, or `configure` fails with
`Secret store entry "X" was not found`. Secret-kind values must come from
`--value-file -` (stdin), never `--value`, which keeps them out of `argv`:

```bash
nemoclaw queeg exec -- sh -c 'printf %s "$VALUE" | \
  openclaw secrets store set MY_TOKEN --kind secret --value-file -'
```

Store ids must match `/^[A-Z][A-Z0-9_]{0,127}$/`.

**Order matters.** Migrating `gateway.auth.token` to a secret-kind store entry
makes it **write-only**, so `nemoclaw <name> gateway-token` stops working and you
can no longer paste the token into the dashboard's login form. Pair every client
you want (browser, TUI) *before* hardening — or set `gateway.auth.password` as a
second way in. Note also that `rebuild` resets `gateway.auth` to a fresh
plaintext token and empties the store, so this hardening is not durable across
rebuilds.

### Model lifecycle and VRAM

The model is **loaded on demand, not held permanently**. Ollama loads it on the
first request and unloads it after `OLLAMA_KEEP_ALIVE` of inactivity (unset here,
so the default **5 minutes**). The sandbox, gateway and agent stay `Ready`
throughout — only GPU memory is released.

| State | VRAM used |
|---|---|
| Idle (model unloaded) | ~1.1 GB — desktop + driver only |
| Model resident | ~21.9 GB of 24.5 GB |

So an empty `ollama ps` and ~1 GB of VRAM is normal, not a fault. The cost is a
~44 s cold load on the next prompt; `start_queeg.sh` pre-loads to avoid that.

`keep_alive` is per-request and the most recent value wins. The pre-warm asks
for 30 m, but OpenClaw's own turns don't specify one, so after each agent reply
the timer reverts to the 5 m default. Net effect: resident while you're working,
released ~5 minutes after you stop.

Deliberately left on-demand, because 21.9 GB is most of the card and this
machine also runs Isaac Sim, Unreal and training jobs. To change it:

```bash
ollama stop qwen38-27b-64k        # release the GPU right now

# or make it permanent (needs sudo + daemon-reload + restart):
#   /etc/systemd/system/ollama.service.d/override.conf
#   Environment="OLLAMA_KEEP_ALIVE=30m"   # longer idle window
#   Environment="OLLAMA_KEEP_ALIVE=-1"    # never unload; holds 21.9 GB forever
```

### Thinking mode

Thinking is **graded, not boolean**. `ollama show` reports levels
`false, low, medium, xhigh`, defaulting to **`medium`** — so the agent reasons
before acting unless told otherwise. Higher levels improve tool selection at a
latency cost. Set it per request:

```bash
curl -s http://127.0.0.1:11434/api/chat -d '{
  "model":"qwen38-27b-64k", "think":"low",
  "messages":[{"role":"user","content":"..."}]}'
```

`"think":false` disables it entirely. Sampling should match the mode, per the
model card:

| Mode | Settings |
|---|---|
| Thinking | `temperature=1.0, top_p=0.95, top_k=20, min_p=0.0` |
| Non-thinking | `temperature=0.7, top_p=0.80, top_k=20, presence_penalty=1.5` |

The `Modelfile` pins the non-thinking values, so raise `temperature` to 1.0 when
running with thinking on.

### Adding a messaging channel

This build is local-only — no third-party credentials, nothing listening
publicly. Channels are additive; to add Telegram, Discord, Slack, WhatsApp,
Teams or Google Chat, re-run onboarding and supply the token through the secure
local helper at `http://127.0.0.1`. Never paste a token into a chat with the
agent: the agent is the untrusted party in this design.

---

## After a reboot

### What comes back on its own

| Component | Mechanism |
|---|---|
| Docker (data-root `/home/docker`) | `docker.service` is **enabled** |
| Ollama + tuning (`q8_0` KV, flash attn, model path) | `ollama.service` is **enabled** |
| Model store bind mount | `/etc/fstab`: `/home/ollama-models → /var/lib/ollama/models` |
| OpenShell gateway | `~/.config/systemd/user/nemoclaw-openshell-gateway.service`, **enabled**; `Linger=yes` (set 2026-10-25), so it starts at **boot**, no login needed |
| DNS wait before the gateway | Drop-in `…/nemoclaw-openshell-gateway.service.d/wait-dns.conf`: waits ≤3 min for `getent hosts github.com` (see below) |
| The sandbox container | Restart policy is `no`, but the gateway runs a **start sweep** on startup (`Started sandbox during gateway startup … started=1`) |
| Agent inside the sandbox | `nemoclaw-start` → `openclaw-gateway`, with heartbeat and dreaming jobs |

**Why the DNS wait exists.** Docker's embedded DNS (`127.0.0.11` in the
container) snapshots upstream nameservers when a container *starts* and never
refreshes them. On this machine Docker is up at ~70 s, Wi-Fi/DHCP at ~137 s, so
without the wait the sandbox started with *no* upstream DNS (`dockerd: DNS
resolver has no external nameservers`) and every egress failed until restarted.

### What does not

| Component | Why |
|---|---|
| Ollama auth proxy on `0.0.0.0:11435` | A detached process started only by interactive `nemoclaw launch`/`connect` (`src/lib/actions/sandbox/connect.ts:2474`). **Until you run `ncl`, the agent is up but every model call fails** |
| Host forward on `127.0.0.1:18789` | A plain process, restored by `start`/`launch` |
| The loaded model | Unloads after `OLLAMA_KEEP_ALIVE` (5 min idle); reloads on first use, ~44 s cold |

`~/.config/systemd/user/nemoclaw-queeg-up.service` (enabled) was meant to start
the proxy at boot via `nemoclaw queeg connect --probe-only`. **It does not
work:** tested 2026-10-25 with the proxy killed, `--probe-only` and
`nemoclaw queeg start` both fail the inference probe and exit 1 without starting
the proxy. So after a reboot, run `ncl` once. Open item: disable that unit, or
find a non-interactive path that calls `ensureOllamaAuthProxy()`.

### One command

`~/scripts/start_queeg.sh` does all of the below, and refuses to guess when the
sandbox is in `Error`. (The `queeg`/`queeg-status` aliases below are **not** in
`~/.bashrc` as of 2026-10-25; call the script directly or use `ncl`.)

```bash
queeg              # alias -> start_queeg.sh: host checks, start, warm model, open TUI
queeg-status       # report only, change nothing
queeg --dashboard  # print the authenticated browser URL instead of opening the TUI
queeg --no-warm    # skip pre-loading the model
```

It needs no sudo: if `docker` or `ollama` is down it prints the command rather
than prompting for a password. It also pre-loads the model with
`keep_alive=30m`, so your first prompt isn't the ~44 s cold load.

### The sequence, manually

```bash
# 1. Log in to your desktop session (starts the user-scoped OpenShell gateway)

# 2. Sanity check the host layer
systemctl is-active docker ollama          # expect: active active
findmnt /var/lib/ollama/models             # expect the bind mount
systemctl --user is-active nemoclaw-openshell-gateway

# 3. Bring the sandbox back
nemoclaw queeg start
nemoclaw queeg status                      # expect Phase: Ready, Inference: healthy

# 4. Use it
nemoclaw launch queeg                      # TUI
nemoclaw queeg dashboard-url --quiet       # or the browser (new tab)
```

If `status` does not reach `Ready`, in escalating order:

```bash
nemoclaw queeg recover        # repairs a stopped gateway and host forwards
nemoclaw queeg doctor         # diagnose; --fix to apply
nemoclaw queeg rebuild --yes  # last resort: recreates the workload
```

`rebuild` is the **only** way out of `Phase: Error` (since `start` requires
`Stopped` and `stop` requires `Ready`), but note it resets `gateway.auth` to a
fresh plaintext token and empties the secret store.

The first prompt after a reboot takes ~44 s while the 17 GB model loads; `ollama
ps` should then show `100% GPU` and `CONTEXT 64000`.

### Autostart on/off

```bash
systemctl --user disable --now nemoclaw-openshell-gateway   # nothing at boot
sudo loginctl disable-linger jack                           # back to start-at-login
```

> The boot sequence above is inferred from unit state, the gateway's own journal
> (start sweep) and dockerd's DNS warning — the DNS drop-in has **not** yet been
> through a real reboot. Check on the next one: `journalctl -b --user -u
> nemoclaw-openshell-gateway` should show the start sweep *after* the DHCP lease
> in `journalctl -b -u dhcpcd`.

### Boot-time clock

The RTC held local time at boot (kernel set the clock to 20:35 UTC when it was
20:35 PDT); `timesyncd` corrected it ~2.5 min later. Effects: Docker reports
"Up 7 hours" on a fresh boot, the gateway logs a 7 h "process frozen", and early
journal timestamps are wrong. Likely Windows dual-boot writing local time — fix
there with `RealTimeIsUniversal`.

## Where things physically live

Everything persistent is on `/home` (836 GB), nothing on the nearly-full root
partition. The agent's state is a **named Docker volume**, not part of the
container's throwaway layer — which is why `rebuild` preserves it.

| What | Host path |
|---|---|
| **Agent workspace + all OpenClaw state** | `/home/docker/volumes/nemoclaw-openclaw-state-v1-queeg/_data` → `/sandbox/.openclaw` |
| ↳ workspace (`AGENTS.md`, `IDENTITY.md`, `POLICY.md`, `SOUL.md`, `USER.md`) | `…/_data/workspace` (~36 KB) |
| ↳ `openclaw.json`, credentials, memory, secret store | `…/_data/` |
| Container writable layer (ephemeral) | `/home/docker/overlay2/<id>/diff` |
| Model weights (~17 GB) | `/home/ollama-models` → `/var/lib/ollama/models` |
| Gateway TLS material | `~/.local/state/nemoclaw/openshell-docker-gateway/tls/` |
| Sandbox identity JWT | `~/.local/state/openshell/docker-sandbox-tokens/…/sandbox.jwt` |
| NemoClaw host state, Ollama proxy token | `~/.nemoclaw/` |

`/home/docker` is root-owned, so you cannot browse the volume directly as your
own user. Use the supported routes instead:

```bash
nemoclaw queeg share mount          # mount the sandbox filesystem on the host
nemoclaw queeg share unmount
nemoclaw queeg download /sandbox/.openclaw/workspace/AGENTS.md
nemoclaw queeg upload ./notes.md
nemoclaw queeg connect              # or just shell in
```

Two things follow from this layout:

- **To back up the agent, back up that volume** (or
  `nemoclaw config export queeg`). The repo holds configuration, not state.
- **The bind-mounted TLS certs are why `~/.local/state` permissions matter.**
  OpenShell validates the whole ancestor chain of its state directory and
  refuses group- or world-write — which is exactly what took the sandbox down
  mid-session once already.

## Arch Linux notes

Arch is **not a validated distro** — NemoClaw validates Ubuntu 24.04 primarily.
Two consequences:

- **CDI specs must be regenerated after every NVIDIA driver upgrade.** Arch ships
  no `nvidia-cdi-refresh.service`, so run this after a driver bump or the
  sandbox loses the GPU:
  ```bash
  sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml && sudo systemctl restart docker
  ```
- The installer's "Station Express" fast path is Ubuntu/DGX-only; the generic
  Linux path is what runs here.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `permission denied ... docker.sock` | Group membership loads only at login: `newgrp docker` |
| Sandbox has no GPU | Stale or missing CDI spec — regenerate (above) |
| Model load times out | Cold load retries once with a 300 s budget; a stale runner needs `systemctl restart ollama` |
| Context reported as 4096 | Ollama is serving `qwen3.8:27b`, not `qwen38-27b-64k` |
| TUI shows `/131k` but Ollama serves 64000 | `models.providers.inference.models[0].contextWindow` in `openclaw.json` defaults to 131072. Silent truncation: the harness never compacts, llama.cpp drops the oldest tokens. Set it to 64000, `gateway restart`, **and relaunch the TUI** — the status bar is fixed at session start |
| `Unsafe OpenShell gateway state directory ... ancestor '~/.local/state'` | OpenShell rejects **group OR world** write on every ancestor of its state dir. `chmod o-w` is not enough — use `chmod go-w` |
| `Phase: Error` and both start/stop refused | Terminal state: `start` needs `Stopped`, `stop` needs `Ready`. Escape with `nemoclaw <name> rebuild --yes` — it recreates the workload and preserves `openclaw.json`, but **resets `gateway.auth` and empties the secret store** |
| `gateway restart` → `transport failed (malformed)` | The in-sandbox gateway died and the container exited. Read the real reason from Docker: `docker logs $(docker ps -aq --filter name=<sandbox>)` |
| Heredoc inside `nemoclaw exec` mangled | Nested heredocs don't survive argument passing. Base64-encode the script: `echo $B64 \| base64 -d \| python3` |
| VRAM spills to host RAM | Lower `num_ctx` to 32000, or drop to `Q4_K_S` |
| Agent cannot reach a host | Working as designed. Widen the policy deliberately |
| `ollama.service` fails: `mkdir /home/...: permission denied` | `ProtectHome=yes` hides `/home` from the unit. Use the bind mount above, not a `/home` path |
| Agent: `LLM request failed: network connection error`, but `status`/`doctor` say inference healthy | Check `nemoclaw queeg logs --tail 300 \| grep -i credential`. **`POST request body credential traffic denied`** = the session transcript contains an `openshell:resolve:…` placeholder (e.g. the agent once ran `env`), and every request resends it. OpenShell rewrites placeholders only in headers, so it denies the body. Fix: `/new` in the TUI. Don't have the agent dump its environment |
| Same error, `doctor` says auth proxy unreachable on `:11435` | Proxy not started since boot. Run `ncl` |
| All egress `CONNECT tunnel failed, response 403`, even active presets | Read the OCSF reason, not the agent's guess. `DNS resolution failed … Try again` = boot DNS race above; fix with `nemoclaw queeg stop && nemoclaw queeg start`, then `ncl` |
| `binary '/usr/local/bin/node' not allowed in policy 'github'` | Presets are per-program: `github` allows only `git`, `pypi` only curl/python/pip/uv |
| `pkill -f <pattern>` kills your own shell | The pattern appears in the shell's command line. Use `pkill -f '[o]llama-auth-proxy'` |
| `pacman -S` 404s on a package | Local db is stale, not the mirror. `sudo pacman -Syu` (a bare `-Sy` + `-S` is a partial upgrade) |

## Verified on this machine

Measured, not assumed — Arch Linux, kernel 7.2.3-arch1-2, RTX 4090 24 GB,
driver 610.57.04 / CUDA 13.3, Ollama 0.40.7, nvidia-container-toolkit 1.20.1.

| Check | Result |
|---|---|
| GPU in container via CDI | `RTX 4090, 610.57.04, 24564 MiB` from a bare `nvidia/cuda` image |
| Model resident | 21786 MiB / 24564 MiB, **100% GPU**, context 64000 |
| Cold load | 44 s |
| Generation throughput | **65.7 tok/s** (175 tokens) |
| Tool calling | `get_weather({"city":"Tokyo"})` — correct name and arguments |
| Quantization | Q4_K_M, 27.3B params, 262144 native context |
| Capabilities | completion, vision, tools, thinking |
| Harness context accounting | `tokens 21k/64k` — matches the server window |

## Security, as measured

These are probe results from inside the running sandbox, not claims from docs.

| Probe | Result |
|---|---|
| Identity | `uid=998(sandbox)`, `CapPrm/CapEff/CapBnd = 0000000000000000` — zero capabilities |
| Host home readable? | `/home/jack`, `.ssh`, `.claude`, `projects` all **absent** from the namespace |
| `/etc/shadow` | `Permission denied` |
| Public internet | `example.com`, `raw.githubusercontent.com`, `api.telegram.org` → `HTTP 000` |
| Raw IP (DNS bypass) | `https://1.1.1.1` → denied |
| `inference.local` from a shell | `{"error":"policy_denied"}` — even `POST /v1/chat/completions` |
| `inference.local` from the agent | **works** |
| Landlock | `ABI V2`, `rules_applied:19`, ro:7 rw:13 (from OCSF audit log) |

The last two rows are the important pair. The *same* endpoint, method and path
is denied to `curl` and permitted to the agent, because the sandbox **identifies
the calling program** before relaying to the supervisor. The boundary is
per-program, not merely per-host.

Your home directory is not merely access-controlled — it is **not in the
sandbox's mount namespace at all**. The only host paths bind-mounted in are
read-only NVIDIA driver libraries.

Two residual risks worth knowing:

- `openclaw.json` inside the sandbox holds credentials the agent can read unless
  migrated to SecretRefs (`openclaw secrets audit --check`). The agent is the
  untrusted party in this design, so this one matters.
- `memory.search` defaults to the **OpenAI** provider. Inert without a key, but
  on a local-only build set `memory.search.enabled false` so conversation
  content can never leave the machine. Still unset as of 2026-10-25
  (`openclaw doctor`: "provider is set to openai but no API key"), so semantic
  recall is also non-functional.

Egress actually observed in the OCSF logs (2026-10-23 → 25): the only LLM
endpoint contacted was `host.openshell.internal:11435`. Other traffic was
tooling — `clawhub.ai`/`catalog.openclaw.ai` (allowed), `telemetry.openclaw.ai`
(denied), GitHub/PyPI via presets, and research APIs (arXiv, OpenAlex, Semantic
Scholar, Crossref — denied). Note the provider is configured as
`models.providers.inference.baseUrl = http://host.openshell.internal:11435/v1`,
i.e. the agent addresses the proxy directly rather than via `inference.local`.

## Layout

```
README.md       this document
setup-host.sh   privileged host preparation (idempotent, --check supported)
Modelfile       num_ctx + sampling for qwen38-27b-64k
.gitignore      keeps weights, state and tokens out of git
```

Outside the repo:

```
~/scripts/start_queeg.sh   one-command startup (see "After a reboot")
~/.bashrc                  ncl, ncl_mount, ncl_umount, ncl_sh, ncl_stop, ncl_list
~/.config/systemd/user/nemoclaw-queeg-up.service                    boot proxy attempt (does NOT work, see above)
~/.config/systemd/user/nemoclaw-openshell-gateway.service.d/wait-dns.conf   boot DNS wait
~/nemoclaw-queeg-backup/   pre-rebuild sandbox state - contains credentials,
                           mode 0700, delete when no longer needed
```