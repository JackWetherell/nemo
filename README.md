# Hermes on NemoClaw

An always-on AI assistant: **Hermes** as the harness, **NVIDIA OpenShell** as the
execution boundary, **DeepSeek v4.1 Flash via OpenRouter** as the model.
**NemoClaw** is NVIDIA's reference stack that wires them together.

The agent runs as an unprivileged, capability-less process that cannot see your
filesystem and cannot open a socket. Inference is remote, so **your prompts do
leave this machine** — they go to OpenRouter and DeepSeek. That is a deliberate
trade for cost, speed and a free GPU; an earlier build of this repo ran the model
locally and its notes are in git history.

---

## The stack

| Layer | Version | Role |
|---|---|---|
| [NemoClaw](https://github.com/NVIDIA/NemoClaw) | v0.0.137 | Installs and manages the stack; applies a versioned blueprint |
| [OpenShell](https://github.com/NVIDIA/OpenShell) | 0.0.116 (docker) | The execution boundary: gateway, supervisor, sandbox |
| Hermes Agent | v0.21.3 | The harness: sessions, tools, OpenAI-compatible API |
| DeepSeek v4.1 Flash | via OpenRouter | The model — 1,048,576 context |

Sandbox name: **`prometheus`**. CLI: **`nemohermes`**.

## How it fits together

```
  you ──► TUI  |  dashboard :18789  |  OpenAI API :8642
                          │
   ┌──────────────────────┼─────────── host (trusted) ──────────┐
   │   ┌──────────────────▼──────┐                              │
   │   │ OpenShell Gateway       │  policy, credentials, JWT    │
   │   └──────────┬──────────────┘                              │
   │   ┌──────────▼──────────────┐                              │
   │   │ Supervisor  (TRUSTED)   │──► openrouter.ai  (allowed)  │
   │   │ holds keys, checks      │──► api.tavily.com (allowed)  │
   │   │ policy, opens sockets   │──X everything else (denied)  │
   │   └──────────▲──────────────┘                              │
   └──────────────┼──── protected channel (sole egress) ────────┘
                  │
   ┌──────────────▼────────── sandbox (untrusted) ──────────────┐
   │  Hermes agent                                              │
   │    · uid 998 `sandbox`, zero Linux capabilities            │
   │    · Landlock confines the filesystem                      │
   │    · default-deny network; no route out but the channel    │
   │    · your home directory is not in its mount namespace     │
   └────────────────────────────────────────────────────────────┘
```

The agent holds no credentials. When it calls OpenRouter, the **supervisor**
attaches the API key after checking policy — the key never enters the sandbox.

## Cost

Measured on a real turn, not estimated:

```
prompt_tokens 11782   completion_tokens 27
```

At $0.14/M in and $0.42/M out that is **$0.00166 per turn** — about a sixth of a
cent. Cost is dominated by Hermes's ~11.8k-token system prompt, re-sent every
turn; replies are rounding error. Roughly **$5/month** at 100 turns/day.

Set a **hard credit limit on the OpenRouter key**, not just the account — an
agent in a tool loop is the thing that spends unexpectedly.

Switch models without reinstalling:

```bash
nemohermes inference set --model deepseek/deepseek-v4-flash \
    --provider openrouter --sandbox prometheus
```

| Model | Context | $/M in | $/M out |
|---|---|---|---|
| `deepseek/deepseek-v4.1-flash` (current) | 1.05M | 0.14 | 0.42 |
| `deepseek/deepseek-v4-flash` | 1.05M | 0.14 | 0.28 |
| `deepseek/deepseek-v4-pro` | 1.05M | 0.955 | 1.911 |

---

## Usage

### Talk to it

```bash
nemohermes launch prometheus              # interactive TUI
~/scripts/start_hermes.sh                 # or the one-command wrapper (alias: hermes)
```

**Hermes exposes an OpenAI-compatible API** — this is the main difference from
OpenClaw, and `nemohermes <name> agent` does *not* work here:

```bash
TOKEN="$(nemohermes prometheus gateway-token --quiet)"
curl -sS http://127.0.0.1:8642/v1/chat/completions \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"hello"}],"stream":false}'
```

Any OpenAI-compatible client can point at `http://127.0.0.1:8642/v1`.

Dashboard: `http://127.0.0.1:18789/` — **open it in a new tab**; changing only a
URL `#fragment` does not reload the page, so the token is never read.

### Lifecycle

```bash
nemohermes prometheus status              # phase, route, policies
nemohermes prometheus recover             # repair gateway + restore port forwards
nemohermes prometheus logs --follow
nemohermes prometheus doctor              # --fix to apply
nemohermes prometheus stop | start
nemohermes prometheus rebuild --yes       # only escape from Phase: Error
nemohermes list
```

**Both ports need a host forward**, and they do not survive a restart.
`recover` restores them — that is what the startup script does first.

### Files in and out

The sandbox cannot see your home directory, so hand files over explicitly:

```bash
nemohermes prometheus upload ./report.csv
nemohermes prometheus download /sandbox/out.md
nemohermes prometheus exec -- ls -la /sandbox
nemohermes prometheus connect
```

---

## Security, as measured

Probe results from inside the running sandbox, not claims from documentation:

| Probe | Result |
|---|---|
| Identity | `uid=998(sandbox)`, `CapEff`/`CapBnd` = `0000000000000000` |
| `/home/jack`, `~/.ssh`, `~/projects` | **ABSENT** from the mount namespace |
| `https://example.com` | `403 CONNECT tunnel failed` → `HTTP 000` |
| OpenRouter / Tavily | allowed, and verified working |
| Policies | `pypi`, `tavily` |

Your files are not merely access-controlled — they are **not in the sandbox's
filesystem at all**. Getting data in requires an explicit `upload` or
`share mount`.

What this build does *not* protect: **content you send it goes to OpenRouter and
DeepSeek.** The boundary stops the agent reaching your disk and the open
internet; it does not make a remote model local.

---

## After a reboot

`Linger=yes` is set, so the OpenShell gateway starts at boot without a login.

| Comes back automatically | Does not |
|---|---|
| Docker (data-root `/home/docker`) | The sandbox container (restart policy `no`) |
| OpenShell gateway (user unit + linger) | Host forwards on `18789` and `8642` |

```bash
~/scripts/start_hermes.sh      # handles both; alias it to `hermes`
```

Or by hand:

```bash
nemohermes prometheus start
nemohermes prometheus recover    # restores the port forwards
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `sandbox agent wrapper cannot dispatch ... it runs 'hermes'` | Expected. Use the API on `:8642`, not `nemohermes <name> agent` |
| Dashboard or API refuses to connect | Forwards are gone. `nemohermes prometheus recover` |
| `Phase: Error`, start and stop both refused | Terminal state. Only `rebuild --yes` escapes — it resets `gateway.auth` and empties the secret store |
| `Unsafe OpenShell gateway state directory` | OpenShell rejects **group or world** write on any ancestor of `~/.local/state`. `chmod go-w`, not just `o-w` |
| Dashboard hangs on a blank page | `#fragment` changes do not reload. Open a fresh tab |
| Install fails on build identity | Pin `NEMOCLAW_INSTALL_REF` to a **release tag**, never a commit SHA |
| Env vars ignored during onboarding | `NEMOCLAW_SANDBOX_NAME` and `NEMOCLAW_WEB_SEARCH_PROVIDER` apply only in non-interactive mode; set them at the prompts |

## Where things live

| What | Path |
|---|---|
| Agent state (named Docker volume) | `/home/docker/volumes/nemoclaw-*-prometheus/_data` |
| NemoClaw host state | `~/.nemoclaw/` |
| Gateway TLS + sandbox JWT | `~/.local/state/nemoclaw/`, `~/.local/state/openshell/` |
| Gateway user unit | `~/.config/systemd/user/nemoclaw-openshell-gateway.service` |

`/home/docker` is root-owned; browse the sandbox with
`nemohermes prometheus share mount` rather than directly.

## Layout

```
README.md        this document
setup-host.sh    host preflight (idempotent, --check supported)
.gitignore       keeps state and tokens out of git
```

Outside the repo: `~/scripts/start_hermes.sh` — one-command startup.
