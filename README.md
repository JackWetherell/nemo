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

| Item | Size |
|---|---|
| Q4_K_M weights | ~16.5 GB |
| q8_0 KV cache @ 64k | ~2.0 GB |
| CUDA context + compute buffers | ~0.8 GB |
| Desktop (Xorg + kwin_x11) | ~1.2 GB |
| **Total** | **~20.5 GB of 24.5 GB** |

That ~4 GB of headroom is deliberate: Qwen3.8-27B is multimodal, and image or
video input consumes both context and activation memory.

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
and writes the Ollama tuning override. It is idempotent, backs up every file it
rewrites, and deletes nothing.

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
`scripts/install.sh` from that clone. Pin the ref for reproducibility:

```bash
NEMOCLAW_INSTALL_REF=8e63c869ae1fe5f5044a102b9cfcdde29b18fd9a \
NEMOCLAW_DISABLE_TELEMETRY=1 \
NEMOCLAW_AGENT=openclaw \
NEMOCLAW_PROVIDER=ollama \
NEMOCLAW_MODEL=qwen38-27b-64k \
NEMOCLAW_POLICY_MODE=suggested \
NEMOCLAW_WEB_SEARCH_PROVIDER=none \
NEMOCLAW_SANDBOX_NAME=my-assistant \
bash /tmp/nemoclaw.sh
```

Run it **in a real terminal** — the installer needs a TTY to authenticate `sudo`
(it probes `sudo -n`, then falls back to `sudo -v` via `/dev/tty`).

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

```bash
openclaw tui                                      # interactive TUI
openclaw agent --agent main --local \
  -m "summarise ~/notes.md" --session-id work      # one-shot, scriptable

nemoclaw list                                     # all sandboxes
nemoclaw my-assistant status                      # health
nemoclaw my-assistant connect                     # shell inside the sandbox
nemoclaw my-assistant logs --follow               # live logs

openshell forward start 18789 my-assistant --background
# → http://127.0.0.1:18789  (token auth)
```

### Thinking mode

Thinking is **on by default** and improves tool selection, at a latency cost.
Sampling differs between modes, per the model card:

| Mode | Settings |
|---|---|
| Thinking | `temperature=1.0, top_p=0.95, top_k=20, min_p=0.0` |
| Non-thinking | `temperature=0.7, top_p=0.80, top_k=20, presence_penalty=1.5` |

The `Modelfile` pins the non-thinking values. Override per-request, or send
`"enable_thinking": false` to disable thinking entirely.

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
| VRAM spills to host RAM | Lower `num_ctx` to 32000, or drop to `Q4_K_S` |
| Agent cannot reach a host | Working as designed. Widen the policy deliberately |

## Layout

```
README.md       this document
setup-host.sh   privileged host preparation (idempotent, --check supported)
Modelfile       num_ctx + sampling for qwen38-27b-64k
.gitignore      keeps weights, state and tokens out of git
```
