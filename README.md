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
| Heredoc inside `nemoclaw exec` mangled | Nested heredocs don't survive argument passing. Base64-encode the script: `echo $B64 \| base64 -d \| python3` |
| VRAM spills to host RAM | Lower `num_ctx` to 32000, or drop to `Q4_K_S` |
| Agent cannot reach a host | Working as designed. Widen the policy deliberately |
| `ollama.service` fails: `mkdir /home/...: permission denied` | `ProtectHome=yes` hides `/home` from the unit. Use the bind mount above, not a `/home` path |
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
  content can never leave the machine.

## Layout

```
README.md       this document
setup-host.sh   privileged host preparation (idempotent, --check supported)
Modelfile       num_ctx + sampling for qwen38-27b-64k
.gitignore      keeps weights, state and tokens out of git
```