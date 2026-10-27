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

---

## Daily operation

Three commands cover almost everything. `hermes` is
`alias hermes='~/scripts/start_hermes.sh'`.

| | Command |
|---|---|
| **1. Start** (after login) | `hermes` |
| **2. Monitor** (while running) | `hermes --status` |
| **3. Stop** (before reboot/shutdown) | `hermes --backup && hermes --stop` |

### 1. Start — after login

```bash
hermes
```

Checks Docker, starts the OpenShell gateway if needed, starts the sandbox,
**restores both host port forwards**, and opens the TUI.

By hand, if you prefer:

```bash
nemohermes prometheus start        # requires phase `Stopped`
nemohermes prometheus recover      # restores forwards on 18789 and 8642
nemohermes launch prometheus       # TUI
```

Other ways in, once started:

```bash
hermes --dashboard                 # prints the browser URL (open in a NEW tab)
hermes --api                       # prints a ready-to-paste curl for :8642
hermes --no-launch                 # prepare everything, do not open the TUI
```

The port forwards **never survive a reboot**. If the dashboard or API refuses to
connect, that is almost always the cause: `nemohermes prometheus recover`.

### 2. Monitor — while running

```bash
hermes --status                    # phase, model, provider, policies, both forwards
```

Deeper, when something looks wrong:

```bash
nemohermes prometheus status       # full status incl. inference health
nemohermes prometheus logs --follow    # live logs + OCSF audit events
nemohermes prometheus doctor       # diagnose; --fix to apply
openshell sandbox list             # authoritative phase
ss -ltn | grep -E '18789|8642'     # are the forwards actually up?
```

What to look for:

| Signal | Healthy |
|---|---|
| `Phase` | `Ready` |
| `Inference` | `healthy (https://openrouter.ai/api/v1/chat/completions)` |
| Forwards | both `18789` and `8642` listening |
| Audit log | `denied_action_count=0` (denials are normal if the agent probes a blocked host) |

Spend is not visible locally — check the **OpenRouter dashboard**. Measured cost
is ~$0.0017 per short turn; research turns with tool use are larger.

### 3. Stop — before reboot or shutdown

```bash
hermes --backup                    # verified host-side copy of the workspace
hermes --stop                      # managed stop -> phase `Stopped`
sudo reboot
```

**Run both, in that order, every time.** This is not housekeeping — see
[Reboots](#reboots--read-this-before-you-reboot). Skipping `--stop` latches the
sandbox at `Error`, whose only recovery is `destroy`, which **deletes the
volume** holding your workspace, venv and skills. `--backup` is what makes that
survivable; it refuses to report success unless live and backup file counts
match.

To stop without rebooting, `hermes --stop` alone is enough. Restart later with
`hermes`.

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

### Less common lifecycle commands

Start, monitor and stop are covered in [Daily operation](#daily-operation).
The rest:

```bash
nemohermes list                           # all sandboxes
nemohermes prometheus rebuild             # upgrade the agent version (interactive)
nemohermes prometheus skill list          # installed skills
nemohermes prometheus policy list         # applied egress presets
nemohermes prometheus sessions list       # conversation sessions
nemohermes prometheus sessions reset <k>  # clear a session that has grown unwieldy
```

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

This is the expensive path. Verified, the hard way:

The container is SIGTERMed by shutdown (`exit 143`); because it vanished rather
than stopping through a managed call, OpenShell latches the sandbox at `Error`.
**Every recovery fails, including rebuild:**

| Attempt | Result |
|---|---|
| `start` | Refused — requires phase `Stopped` |
| `recover` | Fails — needs the container running |
| `docker start <container>` | Container runs fine, **phase stays `Error`** |
| `systemctl --user restart …gateway` | **Phase stays `Error`** |
| `rebuild` / `rebuild --force` | **`Sandbox is unreachable`** — rebuild must reach the sandbox to back it up, and it cannot |
| `openshell sandbox delete` → re-onboard | **The only thing that works** |

The sandbox stays *functionally alive* throughout — supervisor, Hermes gateway
and dashboard all running inside the container. It is purely the gateway's phase
record that is stuck, and no command re-syncs it.

**`destroy` removes the managed state volume.** So the only available recovery
is also the one that deletes `workspace/`, the venv and your skills.

### Back up before you reboot

Because of the above, the volume is *not* a safe home for anything you cannot
regenerate. `/sandbox/.hermes` survives `rebuild` but **not `destroy`**, and an
unclean reboot forces `destroy`.

```bash
~/scripts/start_hermes.sh --backup     # host-side copy of the workspace
~/scripts/start_hermes.sh --stop       # then stop cleanly
sudo reboot
```

To restore into a fresh sandbox:

```bash
CID=$(docker ps -q --filter name=prometheus)
docker cp ~/hermes-workspace-backup-<stamp>/workspace/. "$CID:/sandbox/.hermes/workspace/"
docker exec "$CID" chown -R sandbox:sandbox /sandbox/.hermes/workspace
```

The venv survives this round-trip intact — verified. Everything else needed to
rebuild the agent (policy, skills, AGENTS.md) is version-controlled in this repo,
so a full recovery is roughly five minutes.

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
`/sandbox` is the container's ephemeral overlay, so the workspace and research
venv live under `/sandbox/.hermes`.

That protects them from `rebuild` — **but not from `destroy`, which removes the
volume.** Since an unclean reboot can only be recovered by `destroy`, treat the
volume as durable against upgrades and *not* against accidents. Take host-side
backups (`start_hermes.sh --backup`).

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
