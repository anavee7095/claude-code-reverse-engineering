<p align="center">
  <img src="https://img.shields.io/badge/Status-Complete-brightgreen?style=for-the-badge" alt="Status">
  <img src="https://img.shields.io/badge/Docs-8%20Parts-blue?style=for-the-badge" alt="Docs">
  <img src="https://img.shields.io/badge/Lines-19%2C380-orange?style=for-the-badge" alt="Lines">
  <img src="https://img.shields.io/badge/Verification-8%20Passes-purple?style=for-the-badge" alt="Verification">
</p>

# Claude Code CLI — Reverse Engineering Design Documents

> **Implementation-ready** reverse engineering specifications for Anthropic's [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI tool.
> Extracted via source map analysis of the npm package (March 2026).

---

## At a Glance

```
┌─────────────────────────────────────────────────────────────────────┐
│                      Claude Code CLI                                │
│                                                                     │
│   ~1,900 files  ·  512,000+ LOC  ·  TypeScript Strict  ·  Bun     │
│                                                                     │
│   ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐          │
│   │  React   │  │   Ink    │  │  Yoga    │  │Commander │          │
│   │   19     │  │ (custom  │  │ (WASM    │  │   .js    │          │
│   │          │  │   fork)  │  │  layout) │  │          │          │
│   └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘          │
│        └──────────────┴──────────────┴──────────────┘               │
│                         Terminal UI                                  │
│   ┌─────────────────────────────────────────────────────────────┐   │
│   │                     Core Engine                              │   │
│   │  ┌─────────┐ ┌──────────┐ ┌───────────┐ ┌──────────────┐   │   │
│   │  │  45+    │ │  Query   │ │ Streaming │ │    Cost      │   │   │
│   │  │  Tools  │ │  Engine  │ │ Executor  │ │   Tracker    │   │   │
│   │  └─────────┘ └──────────┘ └───────────┘ └──────────────┘   │   │
│   └─────────────────────────────────────────────────────────────┘   │
│   ┌─────────────────────────────────────────────────────────────┐   │
│   │                    Extension Layer                           │   │
│   │  ┌─────┐ ┌────────┐ ┌────────┐ ┌──────┐ ┌─────┐ ┌──────┐  │   │
│   │  │ MCP │ │Plugins │ │ Skills │ │Hooks │ │ LSP │ │Bridge│  │   │
│   │  └─────┘ └────────┘ └────────┘ └──────┘ └─────┘ └──────┘  │   │
│   └─────────────────────────────────────────────────────────────┘   │
│   ┌─────────────────────────────────────────────────────────────┐   │
│   │                     Services                                 │   │
│   │  ┌────────┐ ┌──────┐ ┌───────────┐ ┌────────┐ ┌─────────┐  │   │
│   │  │  API   │ │ Auth │ │ Analytics │ │Settings│ │Migration│  │   │
│   │  │(4 back)│ │OAuth │ │ DD+OTel  │ │5-layer │ │  chain  │  │   │
│   │  └────────┘ └──────┘ └───────────┘ └────────┘ └─────────┘  │   │
│   └─────────────────────────────────────────────────────────────┘   │
│   ┌─────────────────────────────────────────────────────────────┐   │
│   │                 Security & Permissions                       │   │
│   │  ┌──────────┐ ┌───────────┐ ┌──────────┐ ┌──────────────┐  │   │
│   │  │  7 Perm  │ │ 23 Bash  │ │   Path   │ │  Auto-Mode  │  │   │
│   │  │  Modes   │ │ Checks   │ │Validator │ │ Classifier  │  │   │
│   │  └──────────┘ └───────────┘ └──────────┘ └──────────────┘  │   │
│   └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Design Documents

### Part 1 — Architecture Overview
> [`docs/01-architecture-overview.md`](docs/01-architecture-overview.md) · 1,101 lines

```
Startup Sequence (5 phases)
═══════════════════════════════════════════
Phase 0 ─► Module-level side effects (MDM, Keychain prefetch)
Phase 1 ─► main() entry, basic initialization
Phase 2 ─► Commander preAction → init() → migrations
Phase 3 ─► action() → setup() → auth/permissions
Phase 4 ─► REPL render + deferred prefetches
```

| Topic | Key Details |
|-------|-------------|
| **Module System** | ESM-only, `.js` extensions required, lazy `require()` for cycles |
| **Build** | Bun bundler, `feature()` flags for dead code elimination |
| **Config** | 7 layers: Global → Project → Settings(5 sources) → CLI → MDM |
| **Feature Flags** | 89 flags via GrowthBook, `bun:bundle` compile-time DCE |
| **State** | 110 global fields in `bootstrap/state.ts`, `DO NOT ADD MORE` policy |

---

### Part 2 — Core Engine
> [`docs/02-core-engine.md`](docs/02-core-engine.md) · 1,352 lines

```
Tool Execution Pipeline
═══════════════════════════════════════════
User Input ──► QueryEngine ──► LLM API (streaming)
                                    │
                              tool_use block
                                    │
                    ┌───────────────┼───────────────┐
                    ▼               ▼               ▼
              ┌──────────┐  ┌──────────┐  ┌──────────┐
              │ Bash     │  │ FileEdit │  │ Agent    │
              │ Tool     │  │ Tool     │  │ Tool     │
              └────┬─────┘  └────┬─────┘  └────┬─────┘
                   │             │              │
                   ▼             ▼              ▼
              ToolResult    ToolResult    ToolResult
              { data, newMessages?, contextModifier?, mcpMeta? }
                                    │
                              ◄─────┘
                    Next LLM turn with results
```

| Topic | Key Details |
|-------|-------------|
| **Tool Interface** | 60+ fields, `buildTool()` factory, 7 defaultable keys |
| **Concurrency** | `isConcurrencySafe` flag — safe tools run parallel, unsafe exclusive |
| **Recovery** | 8-stage chain: streaming fallback → model fallback → collapse drain → reactive compact |
| **Cost Tracking** | Per-session USD accumulator, multi-provider normalization |

---

### Part 3 — Permission & Security
> [`docs/03-permission-security.md`](docs/03-permission-security.md) · 1,178 lines

```
Permission Decision Pipeline (4 steps + auto-mode)
═══════════════════════════════════════════════════
Step 0  Config deny rules ──► deny (immediate)
Step 1  Tool.checkPermissions() ──► allow/deny/ask/passthrough
Step 2  Permanent allow rules ──► allow (skip prompt)
Step 3  passthrough → ask conversion
Step 4  Post-processing:
        ├── dontAsk mode ──► auto deny
        ├── auto mode ──► classifier pipeline:
        │   ├── acceptEdits fast-path
        │   ├── safe-tool allowlist
        │   └── YOLO classifier (2-stage)
        │       ├── allowed ──► allow
        │       ├── blocked ──► deny + denial tracking
        │       └── unavailable ──► iron_gate fail-closed
        └── headless ──► hook or deny
```

| Topic | Key Details |
|-------|-------------|
| **7 Modes** | `default`, `plan`, `acceptEdits`, `bypassPermissions`, `dontAsk`, `auto`, `bubble` |
| **Bash Security** | 23 check IDs, 19 cross-platform + 7 Unix + 11 ANT-only patterns |
| **Path Validation** | 6-step: normalize → symlink resolve → traversal → Windows patterns → scope |
| **TOCTOU Warning** | Path validation and file access are not atomic — race condition window |

---

### Part 4 — Multi-Agent & Memory
> [`docs/04-multi-agent-memory.md`](docs/04-multi-agent-memory.md) · 1,416 lines

```
Agent Hierarchy
═══════════════════════════════════════════
                ┌───────────────┐
                │  Coordinator  │  (orchestrator — no direct tool use)
                └───────┬───────┘
           ┌────────────┼────────────┐
           ▼            ▼            ▼
     ┌──────────┐ ┌──────────┐ ┌──────────┐
     │  Worker  │ │  Worker  │ │  Worker  │
     │ (fork)   │ │ (spawn)  │ │(in-proc) │
     └──────────┘ └──────────┘ └──────────┘

Memory Hierarchy (5 layers)
═══════════════════════════════════════════
[1] Session Memory ── in-context summaries
[2] Project Memory ── .claude/memory/ files
[3] User Memory    ── ~/.claude/memory/
[4] Team Memory    ── server-synced shared memory
[5] External       ── MCP servers, LSP, git
```

| Topic | Key Details |
|-------|-------------|
| **3 Swarm Backends** | `fork` (shared context), `spawn` (independent), `in-process teammate` |
| **Task Types** | 7 types with ID prefixes: `b`ash, `w`orkflow, `a`gent, `t`eammate, `r`emote, `m`onitor, `d`ream |
| **Mailbox** | File-based: `.claude/teams/{team}/inboxes/{agent}.json` |
| **Team Sync** | ETag-based conflict detection (412), no local file locking |

---

### Part 5 — Extension Systems
> [`docs/05-extension-systems.md`](docs/05-extension-systems.md) · 1,709 lines

```
6 Extension Points
═══════════════════════════════════════════
┌─────┐ ┌────────┐ ┌────────┐ ┌──────┐ ┌─────┐ ┌──────┐
│ MCP │ │Plugins │ │ Skills │ │Hooks │ │ LSP │ │Bridge│
│     │ │        │ │        │ │      │ │     │ │      │
│8 cfg│ │market- │ │17 bun- │ │27    │ │code │ │IDE   │
│types│ │place + │ │dled +  │ │events│ │intel│ │comms │
│     │ │builtin │ │custom  │ │      │ │     │ │      │
└─────┘ └────────┘ └────────┘ └──────┘ └─────┘ └──────┘
```

| Topic | Key Details |
|-------|-------------|
| **MCP Transports** | `TransportSchema`: 6 types; `McpServerConfig`: 8 (+ ws-ide, claudeai-proxy) |
| **Hook Priority** | `deny` > `ask` > `allow` — any hook's deny overrides all allows |
| **Plugin Loading** | Parallel (marketplace + session) → builtins → merge → dependency verify |
| **Reconnection** | MAX_ERRORS_BEFORE_RECONNECT=3, SSE maxRetries=2, 15min poll timeout |

---

### Part 6 — UI Layer
> [`docs/06-ui-layer.md`](docs/06-ui-layer.md) · 1,784 lines

```
Render Pipeline
═══════════════════════════════════════════
React Component Tree
        │
        ▼
Custom Reconciler (React 19 HostConfig)
        │
        ▼
Yoga Layout Engine (WASM)
        │  ┌──────────────────────┐
        ├──│ Box  (flexbox node)  │
        ├──│ Text (measure func)  │
        └──│ Button (interactive) │
           └──────────────────────┘
        │
        ▼
Output Renderer (ANSI diff)
        │
        ▼
Terminal stdout (throttled at FRAME_INTERVAL_MS)
```

| Topic | Key Details |
|-------|-------------|
| **Ink Fork** | 96 files in `src/ink/`, custom reconciler, Yoga WASM integration |
| **Components** | 346 `.tsx` files in `src/components/` |
| **Hooks** | 85+ custom hooks (`useTextInput`, `useTerminalSize`, `useStdin`, etc.) |
| **Concurrency** | `maySuspendCommit()` always returns `false` — Suspense disabled |

---

### Part 7 — Services & Infrastructure
> [`docs/07-services-infrastructure.md`](docs/07-services-infrastructure.md) · 1,845 lines

```
API Client Factory (4 backends)
═══════════════════════════════════════════
                ┌──────────────────┐
                │  buildFetch()    │
                │  + withRetry()   │
                └────────┬─────────┘
        ┌────────────────┼────────────────┐──────────────┐
        ▼                ▼                ▼              ▼
  ┌──────────┐    ┌──────────┐    ┌──────────┐   ┌──────────┐
  │ Anthropic│    │ Bedrock  │    │ Foundry  │   │ Vertex   │
  │ (Direct) │    │ (AWS)    │    │ (Azure)  │   │ (GCP)    │
  └──────────┘    └──────────┘    └──────────┘   └──────────┘

Retry Strategy:  429 → Retry-After (≤20s: sleep, >20s: 30min cooldown)
                 529 → MAX_529_RETRIES=3 (non-subscriber only)
                 401 → token refresh → retry (no max refresh limit!)
```

| Topic | Key Details |
|-------|-------------|
| **Analytics** | Datadog (44 allowed events, 16 tag fields) + OpenTelemetry + 1P logger |
| **OAuth** | PKCE flow, macOS Keychain with plaintext fallback (30s TTL cache) |
| **Settings Merge** | 5 sources: `user → project → local → flag → policy` (arrays concat, not override!) |
| **Migrations** | 11 sync + 1 async, includes `migrateLegacyOpusToCurrent` (ant-only DCE) |

---

### Part 8 — Types, Schemas & API
> [`docs/08-types-schemas-api.md`](docs/08-types-schemas-api.md) · 2,194 lines

```
Type System Layers
═══════════════════════════════════════════
┌─────────────────────────────────────────┐
│ Branded IDs                              │
│ SessionId, AgentId, TaskId, ToolUseId   │
├─────────────────────────────────────────┤
│ Core Types                               │
│ Tool<I,O,P>, ToolResult<T>,             │
│ ValidationResult, ToolUseContext (30+)   │
├─────────────────────────────────────────┤
│ Zod Schemas                              │
│ HookCommand (discriminated union),       │
│ SettingsSchema (~100 fields),            │
│ TransportSchema (6 literals)             │
├─────────────────────────────────────────┤
│ AppState                                 │
│ DeepImmutable<> wrapper,                 │
│ ~85 fields + Store<T> pattern            │
├─────────────────────────────────────────┤
│ Environment Variables (60+)              │
│ Feature Flags (89)                       │
│ Analytics Events (44 Datadog)            │
└─────────────────────────────────────────┘
```

| Topic | Key Details |
|-------|-------------|
| **SettingsJson** | ~100 fields across 15 categories (auth, permissions, MCP, hooks, model, UI...) |
| **Settings Merge** | `policySettings` internal priority: remote > HKLM/plist > file > HKCU |
| **Env Vars** | 60+ variables across 7 groups (API, model, auth, debug, feature, proxy, internal) |
| **Feature Flags** | 89 `bun:bundle` `feature()` calls, compile-time dead code elimination |

---

## Infrastructure & Deployment

> [`infrastructure/`](infrastructure/) — Complete deployment blueprints with Terraform IaC

```
Deployment Options
═══════════════════════════════════════════
┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│   Local Dev  │  │     AWS      │  │    Azure     │  │  Supabase    │
│              │  │              │  │              │  │              │
│ Ollama/vLLM  │  │ ECS Fargate  │  │ Container   │  │ Edge Funcs   │
│ Docker Stack │  │ Bedrock      │  │ Apps         │  │ Realtime     │
│ RTX 4090     │  │ Lambda       │  │ Azure OpenAI │  │ PostgreSQL   │
│              │  │ Cognito      │  │ AD B2C       │  │ Auth         │
│ $0-50/mo     │  │ $45-180/mo   │  │ $50-190/mo   │  │ $0-25/mo     │
└──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘
```

| Document | Description |
|----------|-------------|
| [`01-local-development.md`](infrastructure/01-local-development.md) | Ollama, vLLM, LM Studio, Docker Compose full stack |
| [`02-aws-architecture.md`](infrastructure/02-aws-architecture.md) | VPC, ECS, Bedrock, Lambda sandbox, CloudWatch |
| [`03-azure-architecture.md`](infrastructure/03-azure-architecture.md) | Container Apps, Azure OpenAI, Functions, Monitor |
| [`04-supabase-backend.md`](infrastructure/04-supabase-backend.md) | 10-table schema, RLS policies, Edge Functions |
| [`05-cost-analysis.md`](infrastructure/05-cost-analysis.md) | Real pricing: $9/mo solo → $25/dev enterprise |
| [`06-architecture-diagram.md`](infrastructure/06-architecture-diagram.md) | 7 ASCII diagrams: system, data flow, auth, agents |
| [`terraform/`](infrastructure/terraform/) | 10 `.tf` files — production-ready AWS IaC |

### Cost Quick Reference

| Scale | Supabase + API | AWS Full | Hybrid (Local GPU) |
|-------|:--------------:|:--------:|:-------------------:|
| **Solo** (1 dev) | $9–103/mo | $180/mo | $50/mo |
| **Team** (10 devs) | $46–116/dev | $65–110/dev | $35–60/dev |
| **Enterprise** (100 devs) | N/A | $45–111/dev | **$25/dev** |

> LLM token costs represent 60–95% of total spend at every scale.

---

## Verification Status

These documents went through **8 rigorous verification passes** against the actual source code:

```
Pass 1 ████████████████ 16 corrections  (type/value accuracy)
Pass 2 ████             4 fixes         (blocking implementation gaps)
Pass 3 ███████          7 corrections   (line-by-line precision)
Pass 4 ███              3 fixes         (missing schemas/flows)
Pass 5 ███████          7 additions     (Bridge, MDM, Keychain, Plugin)
Pass 6 ██████████████   42 caveats      (structural problem warnings)
Pass 7 ██               2 micro-fixes   (convergence check)
Pass 8 ─────────────── CONVERGED        (24/24 spot-checks verified)
       ═══════════════
Total: 39 corrections + 42 implementation caveats
```

---

## Quick Start

```bash
# Clone the repo
git clone https://github.com/jung-wan-kim/claude-code-reverse-engineering.git
cd claude-code-reverse-engineering

# Read the design docs (start here)
open docs/01-architecture-overview.md

# Deploy infrastructure (AWS)
cd infrastructure/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your settings
terraform init && terraform plan
```

---

## Repository Structure

```
claude-code-reverse-engineering/
├── README.md                          ← You are here
├── docs/
│   ├── 01-architecture-overview.md    (1,101 lines)
│   ├── 02-core-engine.md             (1,352 lines)
│   ├── 03-permission-security.md     (1,178 lines)
│   ├── 04-multi-agent-memory.md      (1,416 lines)
│   ├── 05-extension-systems.md       (1,709 lines)
│   ├── 06-ui-layer.md               (1,784 lines)
│   ├── 07-services-infrastructure.md (1,845 lines)
│   └── 08-types-schemas-api.md       (2,194 lines)
└── infrastructure/
    ├── 01-local-development.md
    ├── 02-aws-architecture.md
    ├── 03-azure-architecture.md
    ├── 04-supabase-backend.md
    ├── 05-cost-analysis.md
    ├── 06-architecture-diagram.md
    └── terraform/
        ├── main.tf
        ├── variables.tf
        ├── vpc.tf
        ├── compute.tf
        ├── database.tf
        ├── storage.tf
        ├── auth.tf
        ├── monitoring.tf
        ├── outputs.tf
        └── terraform.tfvars.example
```

---

## Disclaimer

This is a reverse-engineering effort for **educational and security research purposes only**. All rights to the original Claude Code software belong to [Anthropic](https://www.anthropic.com/).

## License

MIT (documentation only — does not cover the original Claude Code software)
