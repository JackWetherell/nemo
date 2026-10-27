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

| Model | Context | $/M in | $/M out | Images |
|---|---|---|---|---|
| `deepseek/deepseek-v4.1-flash` (current) | 1.05M | 0.14 | 0.42 | **yes** |
| `deepseek/deepseek-v4-flash` | 1.05M | 0.14 | 0.28 | **no — text only** |
| `deepseek/deepseek-v4-pro` | 1.05M | 0.955 | 1.911 | yes |

**Do not switch to `v4-flash` to save $0.14/M on output.** Its
`input_modalities` is `["text"]` — the saving silently removes image support,
which the research agent needs for figures and typeset equations. Verify before
switching:

```bash
curl -s https://openrouter.ai/api/v1/models \
  | jq -r '.data[] | select(.id=="<model>") | .architecture.input_modalities'
```

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

## Reboots — read this before you reboot

**A plain `sudo reboot` leaves the sandbox permanently in `Phase: Error`, and
the only exit is a rebuild.** This is verified behaviour, not a theory. Shut the
sandbox down cleanly first and the problem does not arise.

### Before rebooting

```bash
nemohermes prometheus stop        # managed stop -> lands in `Stopped`, not `Error`
sudo reboot
```

### After booting

```bash
~/scripts/start_hermes.sh         # alias: hermes
```

The script starts the gateway if needed, starts the sandbox, and runs `recover`
to restore the two host forwards — which never survive a reboot.

By hand:

```bash
nemohermes prometheus start       # requires phase `Stopped`
nemohermes prometheus recover     # restores forwards on 18789 and 8642
```

### What survives a reboot

| Comes back automatically | Does not |
|---|---|
| Docker (data-root `/home/docker`) | The sandbox container — restart policy is `no` |
| OpenShell gateway (user unit, `Linger=yes`, so no login needed) | Host forwards on `18789` and `8642` |

### If you rebooted without stopping first

The container is SIGTERMed by the shutdown sequence (`exit 143`) and, because it
vanished rather than stopping through a managed call, OpenShell latches the
sandbox at `Error`. Every non-destructive repair fails — all four were tried:

| Attempt | Result |
|---|---|
| `nemohermes <name> start` | Refused — `start` requires `Stopped` |
| `nemohermes <name> recover` | Fails — needs the container running |
| `docker start <container>` | Container runs, **phase stays `Error`** |
| `systemctl --user restart nemoclaw-openshell-gateway` | **Phase stays `Error`** |

The `Error` phase lives in the gateway's state store, not the container, and
survives both. Only this clears it:

```bash
nemohermes prometheus rebuild     # interactive - it preflights credentials
```

Use the interactive form. `--yes` aborts at preflight if a channel credential
(e.g. `TAVILY_API_KEY`) is not available non-interactively — safely, leaving the
sandbox untouched, but you still have to supply the key.

A rebuild preserves everything on the volume (`workspace/`, the research venv,
skills, `config.yaml`) and resets `gateway.auth` plus the secret store.

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

## The physics research agent

`prometheus` doubles as a physics research collaborator. See
`workspace/AGENTS.md` for the working rules it follows.

| Piece | Where |
|---|---|
| Workspace | `/sandbox/.hermes/workspace` (persistent) |
| Scientific Python | `…/workspace/.venv/bin/python` — numpy, scipy, sympy, matplotlib, pandas, pint, pymupdf |
| Pinned versions | `…/workspace/environment.lock` |
| Custom skills | `physics-derivation`, `physics-numerics`, `physics-report`, `physics-review` |
| Shipped skills reused | `research/arxiv`, `research/grounded-citations`, `pdf` |
| Literature egress | arXiv + Crossref via the `physics-research` policy preset |

Source of truth for all of it is this repo: `policy/`, `skills/`, `workspace/`.

### The persistence boundary — read this before storing anything

**Only `/sandbox/.hermes` is on the Docker volume.** Everything else in
`/sandbox` is the container's ephemeral overlay and is destroyed by
`rebuild --yes`, which is the only escape from `Phase: Error`. The workspace and
the research venv both live under `/sandbox/.hermes` for exactly this reason.

### The `binaries:` allowlist — why a new venv has no network

OpenShell policies bind each endpoint to specific executables. The live `pypi`
policy permits `/opt/hermes/.venv/bin/python` but not a venv elsewhere, so
`pip install` into a new venv is **denied**, not slow. Any new interpreter must
be added to a policy's `binaries:` list — see `policy/physics-research.yaml`.
Verified: `node` is refused an allowed host; the listed venv python is not.

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
