# Part 4: Multi-Agent & Memory System

## Table of Contents

1. [Coordinator Mode](#1-coordinator-mode)
2. [Agent Swarm System](#2-agent-swarm-system)
3. [Permission Synchronization](#3-permission-synchronization)
4. [AgentTool Implementation](#4-agenttool-implementation)
5. [SendMessage Protocol](#5-sendmessage-protocol)
6. [Memory System 5 Layers](#6-memory-system-5-layers)
7. [Memory Storage Paths](#7-memory-storage-paths)
8. [Team Memory Synchronization](#8-team-memory-synchronization)
9. [Auto-Dream Integration](#9-auto-dream-integration)
10. [Task System](#10-task-system)

---

## 1. Coordinator Mode

### Overview

Coordinator mode is an orchestration mode activated via the `CLAUDE_CODE_COORDINATOR_MODE=1` environment variable. When active, the main agent does not execute tools directly but instead spawns worker agents to delegate tasks.

### System Prompt Structure (369 lines, entire coordinatorMode.ts)

```typescript
// src/coordinator/coordinatorMode.ts

export function getCoordinatorSystemPrompt(): string {
  // Returns system prompt composed of 6 sections
}
```

**Section structure:**

| Section | Content |
|---------|---------|
| `## 1. Your Role` | Coordinator role definition. Does not write code directly, only orchestrates |
| `## 2. Your Tools` | Agent, SendMessage, TaskStop, subscribe_pr_activity tool descriptions |
| `## 3. Workers` | Worker subagent_type usage, worker tool inventory |
| `## 4. Task Workflow` | 4-stage workflow: Research/Synthesis/Implementation/Verification |
| `## 5. Writing Worker Prompts` | Prompt writing guide: synthesis, continue vs spawn decision criteria |
| `## 6. Example Session` | Full session example (research -> fix -> verification) |

### task-notification XML Format

Worker results arrive as user-role messages in `<task-notification>` XML format:

```xml
<task-notification>
  <task-id>{agentId}</task-id>
  <status>completed|failed|killed</status>
  <summary>{human-readable status summary}</summary>
  <result>{agent's final text response}</result>
  <usage>
    <total_tokens>N</total_tokens>
    <tool_uses>N</tool_uses>
    <duration_ms>N</duration_ms>
  </usage>
</task-notification>
```

### Worker Tool Restrictions

```typescript
// Worker tools in CLAUDE_CODE_SIMPLE mode
const SIMPLE_WORKER_TOOLS = ['Bash', 'Edit', 'Read']

// Normal mode worker tools = ASYNC_AGENT_ALLOWED_TOOLS minus internal tools
const INTERNAL_WORKER_TOOLS = new Set([
  'TeamCreate',
  'TeamDelete',
  'SendMessage',
  'SyntheticOutput',
])
```

### Session Mode Matching

```typescript
export function matchSessionMode(
  sessionMode: 'coordinator' | 'normal' | undefined,
): string | undefined
```

Automatically switches environment variables when a resumed session's mode differs from the current environment. This prevents mismatches when resuming a coordinator session in normal mode.

### Scratchpad Directory

```typescript
if (scratchpadDir && isScratchpadGateEnabled()) {
  content += `\nScratchpad directory: ${scratchpadDir}
Workers can read and write here without permission prompts.
Use this for durable cross-worker knowledge.`
}
```

Provides a shared directory accessible without permission prompts for cross-worker knowledge sharing.

---

## 2. Agent Swarm System

### TeammateExecutor Interface

```typescript
// src/utils/swarm/backends/types.ts

type TeammateExecutor = {
  readonly type: BackendType  // 'tmux' | 'iterm2' | 'in-process'
  isAvailable(): Promise<boolean>
  spawn(config: TeammateSpawnConfig): Promise<TeammateSpawnResult>
  sendMessage(agentId: string, message: TeammateMessage): Promise<void>
  terminate(agentId: string, reason?: string): Promise<boolean>
  kill(agentId: string): Promise<boolean>
  isActive(agentId: string): Promise<boolean>
}
```

### TeammateSpawnConfig

```typescript
type TeammateSpawnConfig = TeammateIdentity & {
  prompt: string
  cwd: string
  model?: string
  systemPrompt?: string
  systemPromptMode?: 'default' | 'replace' | 'append'
  worktreePath?: string
  parentSessionId: string
  permissions?: string[]
  allowPermissionPrompts?: boolean
}

type TeammateIdentity = {
  name: string
  teamName: string
  color?: AgentColorName
  planModeRequired?: boolean
}
```

### TeammateSpawnResult

```typescript
type TeammateSpawnResult = {
  success: boolean
  agentId: string           // format: "agentName@teamName"
  error?: string
  abortController?: AbortController  // in-process only
  taskId?: string                     // in-process only
  paneId?: PaneId                     // pane-based only
}
```

### 3 Backend Implementations

#### TmuxBackend

```typescript
// src/utils/swarm/backends/TmuxBackend.ts

class TmuxBackend implements PaneBackend {
  readonly type = 'tmux'
  readonly supportsHideShow = true

  // Running inside tmux: leader 30% | teammates 70% (main-vertical)
  // Running outside tmux: tiled layout in separate claude-swarm session

  async createTeammatePaneInSwarmView(
    name: string, color: AgentColorName
  ): Promise<CreatePaneResult>
}
```

**Key behavior:**
- Captures leader pane ID from `TMUX_PANE` environment variable at module load time
- Lock mechanism prevents parallel spawn race conditions during pane creation
- 200ms wait after pane creation (shell initialization: starship/oh-my-zsh support)
- Inside leader: `split-window -h -l 70%` (first teammate), then binary splits
- Outside leader: `swarm-view` window in separate socket's `claude-swarm` session

#### ITermBackend

```typescript
// src/utils/swarm/backends/ITermBackend.ts

class ITermBackend implements PaneBackend {
  readonly type = 'iterm2'
  readonly supportsHideShow = false  // break-pane not supported

  // Uses it2 CLI (Python API)
  // Leader on left, teammates in right vertical stack
  // Color/title settings are no-ops for performance
}
```

**Key behavior:**
- Extracts leader session ID from `ITERM_SESSION_ID` environment variable
- `it2 session split -v -s <leaderSessionId>` for first split
- Subsequent `it2 session split -s <lastTeammateId>` for stacking
- Dead session detection with prune and retry (at-fault recovery)
- `it2 session close -f` (-f required: bypasses "Confirm before closing")

#### InProcessBackend

```typescript
// src/utils/swarm/backends/InProcessBackend.ts

class InProcessBackend implements TeammateExecutor {
  readonly type = 'in-process'
  private context: ToolUseContext | null = null

  setContext(context: ToolUseContext): void
  async spawn(config: TeammateSpawnConfig): Promise<TeammateSpawnResult>
  async sendMessage(agentId: string, message: TeammateMessage): Promise<void>
  async terminate(agentId: string, reason?: string): Promise<boolean>
  async kill(agentId: string): Promise<boolean>
}
```

**Key behavior:**
- Context isolation via AsyncLocalStorage within the same Node.js process
- Shares API client, MCP connections, and other resources with leader
- File-based mailbox for communication (same as pane-based)
- Termination control via AbortController
- Auto-selected for non-interactive sessions (-p mode)

### Backend Detection Priority

```typescript
// src/utils/swarm/backends/registry.ts

// 1. Running inside tmux -> tmux
// 2. iTerm2 + it2 CLI -> iterm2
// 3. iTerm2 - it2 + tmux -> tmux (with it2 installation guidance)
// 4. tmux available -> tmux (external session)
// 5. Non-interactive (-p) -> in-process
// 6. auto mode + no tmux/iTerm2 -> in-process fallback
```

```typescript
function isInProcessEnabled(): boolean {
  if (getIsNonInteractiveSession()) return true
  const mode = getTeammateMode()  // 'auto' | 'tmux' | 'in-process'
  if (mode === 'in-process') return true
  if (mode === 'tmux') return false
  // auto: environment-based determination
  if (inProcessFallbackActive) return true
  return !isInsideTmuxSync() && !isInITerm2()
}
```

### TeamFile Structure

```typescript
// src/utils/swarm/teamHelpers.ts

type TeamFile = {
  name: string
  description?: string
  createdAt: number
  leadAgentId: string
  leadSessionId?: string
  hiddenPaneIds?: string[]
  teamAllowedPaths?: TeamAllowedPath[]
  members: Array<{
    agentId: string
    name: string
    agentType?: string
    model?: string
    prompt?: string
    color?: string
    planModeRequired?: boolean
    joinedAt: number
    tmuxPaneId: string
    cwd: string
    worktreePath?: string
    sessionId?: string
    subscriptions: string[]
    backendType?: BackendType
    isActive?: boolean
    mode?: PermissionMode
  }>
}
```

**Storage path:** `~/.claude/teams/{team-name}/config.json`

### Spawn Flow

```
TeamCreateTool.call()
  -> Create TeamFile (config.json)
  -> Register session cleanup (registerTeamForSessionCleanup)
  -> Create task list directory (~/.claude/tasks/{team-name}/)
  -> Update AppState.teamContext

AgentTool.call() (with team_name + name specified)
  -> getTeammateExecutor(preferInProcess)
  -> executor.spawn(config)
    -> [In-Process] spawnInProcessTeammate() -> startInProcessTeammate()
    -> [Pane-Based] createTeammatePaneInSwarmView() -> sendCommandToPane()
  -> Add to TeamFile.members
```

---

## 3. Permission Synchronization

### Dual-Path System

When a worker agent needs permission, it sends requests to the leader through two paths:

#### File-Based (pending/resolved directories)

```typescript
// src/utils/swarm/permissionSync.ts

// Directory structure
// ~/.claude/teams/{teamName}/permissions/
//   pending/   <- worker writes requests
//   resolved/  <- leader writes responses

type SwarmPermissionRequest = {
  id: string
  workerId: string
  workerName: string
  workerColor?: string
  teamName: string
  toolName: string
  toolUseId: string
  description: string
  input: Record<string, unknown>
  permissionSuggestions: unknown[]
  status: 'pending' | 'approved' | 'rejected'
  resolvedBy?: 'worker' | 'leader'
  resolvedAt?: number
  feedback?: string
  updatedInput?: Record<string, unknown>
  permissionUpdates?: unknown[]
  createdAt: number
}
```

**Flow:**
1. Worker writes JSON to `pending/` directory via `writePermissionRequest()` (using lockfile)
2. Leader reads pending requests via `readPendingPermissions()`
3. User approves/denies in leader UI
4. `resolvePermission()` writes to `resolved/` and deletes from `pending/`
5. Worker checks result via `pollForResponse()`

#### Mailbox-Based

```typescript
// Newer approach: replaces file-based pending/resolved

async function sendPermissionRequestViaMailbox(
  request: SwarmPermissionRequest
): Promise<boolean>

async function sendPermissionResponseViaMailbox(
  workerName: string,
  resolution: PermissionResolution,
  requestId: string,
  teamName?: string
): Promise<boolean>
```

The mailbox-based approach uses the `writeToMailbox()` function and works for both in-process and pane-based teammates.

### Leader Permission Bridge

```typescript
// src/utils/swarm/leaderPermissionBridge.ts

// Module-level bridge for in-process teammates to display
// permission prompts via the leader's REPL UI

type SetToolUseConfirmQueueFn = (
  updater: (prev: ToolUseConfirm[]) => ToolUseConfirm[],
) => void

type SetToolPermissionContextFn = (
  context: ToolPermissionContext,
  options?: { preserveMode?: boolean },
) => void

// REPL registers -> in-process runner uses
registerLeaderToolUseConfirmQueue(setter: SetToolUseConfirmQueueFn): void
getLeaderToolUseConfirmQueue(): SetToolUseConfirmQueueFn | null
```

In-process teammates use the standard `ToolUseConfirm` dialog, directly accessing the leader's UI queue to display native permission prompts instead of worker permission badges.

### Sandbox Permissions (Network Access)

```typescript
async function sendSandboxPermissionRequestViaMailbox(
  host: string,
  requestId: string,
  teamName?: string
): Promise<boolean>

async function sendSandboxPermissionResponseViaMailbox(
  workerName: string,
  requestId: string,
  host: string,
  allow: boolean,
  teamName?: string
): Promise<boolean>
```

---

## 4. AgentTool Implementation

### Input Schema (10 fields)

```typescript
// Extracted from AgentTool.tsx full input schema

type AgentToolInput = {
  // Required
  prompt: string            // Task description to pass to agent
  description: string       // 3-5 word summary displayed in UI

  // Agent type
  subagent_type?: string    // Agent type (omit for fork or general-purpose)

  // Execution control
  run_in_background?: boolean  // Background execution (async)
  model?: string              // Model override

  // Swarm-related
  name?: string              // Agent name (for SendMessage reference)
  team_name?: string         // Team name to join
  mode?: string              // Permission mode

  // Isolation
  isolation?: 'worktree' | 'remote'  // git worktree isolation or remote CCR

  // Working directory
  cwd?: string               // Agent execution directory (absolute path)
}
```

### Fork vs Spawn Decision

```typescript
// src/tools/AgentTool/forkSubagent.ts

function isForkSubagentEnabled(): boolean {
  // FORK_SUBAGENT feature flag is on,
  // not in coordinator mode,
  // and not in non-interactive session
  if (feature('FORK_SUBAGENT')) {
    if (isCoordinatorMode()) return false
    if (getIsNonInteractiveSession()) return false
    return true
  }
  return false
}
```

| Condition | Behavior |
|-----------|----------|
| `subagent_type` specified | Spawn new agent (zero context) |
| `subagent_type` omitted + fork enabled | Fork (inherits parent context) |
| `subagent_type` omitted + fork disabled | Spawn general-purpose agent |

### Fork Mechanism

```typescript
// Fork child message building
function buildForkedMessages(
  directive: string,
  assistantMessage: AssistantMessage,
): MessageType[] {
  // 1. Retain parent's entire assistant message (all tool_use blocks)
  // 2. Generate identical placeholder results for all tool_uses
  // 3. Add per-child directive as last text block
  // -> Maximizes prompt cache sharing
}

// Fork child message (10 non-negotiable rules)
function buildChildMessage(directive: string): string {
  // 1. No spawning subagents
  // 2. No conversations/questions
  // 3. Use tools directly
  // 4. Include commits with file modifications
  // 5. No text between tool calls
  // 6. Stay within scope
  // 7. Report under 500 words
  // 8. Start with "Scope:"
  // ...
}
```

### Fork Agent Definition

```typescript
const FORK_AGENT: BuiltInAgentDefinition = {
  agentType: 'fork',
  tools: ['*'],           // Same tools as parent
  model: 'inherit',       // Inherit parent model (cache sharing)
  permissionMode: 'bubble', // Forward permission prompts to parent terminal
  maxTurns: 200,
}
```

### Worktree Isolation

```typescript
function buildWorktreeNotice(
  parentCwd: string, worktreeCwd: string
): string {
  // Guide converting parent context paths to worktree root
  // Instruct to re-read files before editing
  // Explain that changes do not affect parent
}
```

When `isolation: "worktree"` is set, the agent runs in a temporary git worktree and is automatically cleaned up if there are no changes.

### Async Agent Lifecycle

```typescript
// src/tools/AgentTool/agentToolUtils.ts

async function runAsyncAgentLifecycle({
  taskId,
  abortController,
  makeStream,
  metadata,
  description,
  toolUseContext,
  rootSetAppState,
  agentIdForCleanup,
  enableSummarization,
  getWorktreeResult,
}: RunAsyncAgentLifecycleParams): Promise<void> {
  // 1. Create ProgressTracker
  // 2. Start agent summarization if enabled
  // 3. Consume message stream while updating progress state
  // 4. On completion: completeAsyncAgent -> enqueueAgentNotification
  // 5. On abort: killAsyncAgent -> notification (partial result)
  // 6. On error: failAsyncAgent -> notification
  // 7. finally: clearInvokedSkillsForAgent, clearDumpState
}
```

### Tool Filtering

```typescript
function filterToolsForAgent({
  tools, isBuiltIn, isAsync, permissionMode
}: FilterParams): Tools {
  // 1. MCP tools always allowed
  // 2. ExitPlanMode only in plan mode
  // 3. Remove tools in ALL_AGENT_DISALLOWED_TOOLS
  // 4. Remove CUSTOM_AGENT_DISALLOWED_TOOLS for custom agents
  // 5. Async agents only get ASYNC_AGENT_ALLOWED_TOOLS
  // 6. In-process teammates get AgentTool + IN_PROCESS_TEAMMATE_ALLOWED_TOOLS
}
```

### Agent Definition Source Priority

```
built-in -> plugin -> userSettings -> projectSettings -> flagSettings -> policySettings
```

Later sources override the same `agentType` definitions.

---

## 5. SendMessage Protocol

### Structured Message Types

```typescript
// src/tools/SendMessageTool/SendMessageTool.ts

const StructuredMessage = z.discriminatedUnion('type', [
  z.object({
    type: z.literal('shutdown_request'),
    reason: z.string().optional(),
  }),
  z.object({
    type: z.literal('shutdown_response'),
    request_id: z.string(),
    approve: semanticBoolean(),
    reason: z.string().optional(),
  }),
  z.object({
    type: z.literal('plan_approval_response'),
    request_id: z.string(),
    approve: semanticBoolean(),
    feedback: z.string().optional(),
  }),
])
```

### Message Routing

```typescript
type Input = {
  to: string      // Recipient: name, "*", "uds:socket_path", "bridge:session_id"
  summary?: string // 5-10 word UI preview
  message: string | StructuredMessage  // Content
}
```

| `to` Value | Target |
|------------|--------|
| `"researcher"` | Teammate by name |
| `"*"` | Full broadcast (O(N)) |
| `"uds:/path/to.sock"` | Local UDS socket peer |
| `"bridge:session_..."` | Remote Control peer |

### Routing Flow

```
SendMessageTool.call(input)
  -> [bridge address] postInterClaudeMessage()
  -> [uds address] sendToUdsSocket()
  -> [subagent name/ID]
       -> task.status === 'running' ? queuePendingMessage()
       -> task.status !== 'running' ? resumeAgentBackground()
       -> task not found ? resumeAgentBackground() (disk transcript)
  -> [broadcast "*"] handleBroadcast() -> writeToMailbox() for all members
  -> [regular name] handleMessage() -> writeToMailbox()
```

### Shutdown Protocol

```
Leader -> shutdown_request -> Worker mailbox
Worker -> shutdown_response(approve=true) -> Leader mailbox
  -> [in-process] AbortController.abort()
  -> [pane-based] gracefulShutdown(0)
Worker -> shutdown_response(approve=false, reason) -> Leader mailbox
  -> Work continues
```

### Plan Approval Protocol

```
Worker (plan mode) -> plan_approval_request -> Leader mailbox
Leader -> plan_approval_response(approve=true) -> Worker mailbox
  -> permissionMode inherits leader's current mode
Leader -> plan_approval_response(approve=false, feedback) -> Worker mailbox
  -> Worker revises and resubmits
```

### Mailbox System

All teammate communication uses the `writeToMailbox()` function:

```typescript
// src/utils/teammateMailbox.ts

async function writeToMailbox(
  recipientName: string,
  message: {
    from: string
    text: string
    summary?: string
    timestamp: string
    color?: string
  },
  teamName?: string,
): Promise<void>
```

The mailbox is filesystem-based, stored as a single file at `.claude/teams/{teamName}/inboxes/{agentName}.json`. It is a single JSON file (not a directory), and messages are automatically delivered without manual inbox checking.

---

## 6. Memory System 5 Layers

Claude Code's memory consists of 5 layers:

```
[1] Session Memory ─ In-session context summaries
        |
[2] Agent Memory ─ Per-agent persistent memory
        |
[3] Auto Extraction ─ Automatic memory extraction from conversations
        |
[4] Team Memory Sync ─ Cross-team memory sharing (OAuth)
        |
[5] Auto-Dream ─ Periodic memory consolidation/cleanup
```

### Layer 1: Session Memory

```typescript
// src/services/SessionMemory/sessionMemory.ts

// Automatically maintains markdown notes within a session
// Forked subagent runs periodically in the background

type SessionMemoryConfig = {
  minimumMessageTokensToInit: number    // Minimum tokens for initialization
  minimumTokensBetweenUpdate: number    // Minimum tokens between updates
  toolCallsBetweenUpdates: number       // Minimum tool calls between updates
}

// Trigger condition: (token threshold + tool call threshold) OR (token threshold + non-tool turn)
function shouldExtractMemory(messages: Message[]): boolean
```

**Storage location:** `~/.claude/projects/{slug}/session-memory.md`
**Tool restrictions:** Only `Edit` tool allowed (specifically for the memory file)

### Layer 2: Agent Memory

```typescript
// src/tools/AgentTool/agentMemory.ts

type AgentMemoryScope = 'user' | 'project' | 'local'

// Directory structure
// user:    ~/.claude/agent-memory/{agentType}/MEMORY.md
// project: .claude/agent-memory/{agentType}/MEMORY.md
// local:   .claude/agent-memory-local/{agentType}/MEMORY.md

function loadAgentMemoryPrompt(
  agentType: string,
  scope: AgentMemoryScope,
): string
```

When the `memory` field in an agent definition specifies a scope, the contents of that scope's memory directory are included in the system prompt when the agent spawns. Agents with active memory automatically have `Write`, `Edit`, `Read` tools injected.

### Snapshot Synchronization

```typescript
// src/tools/AgentTool/agentMemorySnapshot.ts

// If .claude/agent-memory-snapshots/{agentType}/snapshot.json exists in project
// Copy to local on first run (initialize)
// Notify via prompt when snapshot is updated (prompt-update)

async function checkAgentMemorySnapshot(
  agentType: string, scope: AgentMemoryScope
): Promise<{
  action: 'none' | 'initialize' | 'prompt-update'
  snapshotTimestamp?: string
}>
```

### Layer 3: Auto Extraction

```typescript
// src/services/extractMemories/extractMemories.ts

// Runs on every query loop completion (fire-and-forget from stopHooks)
// runForkedAgent shares parent's prompt cache as a fork agent

function initExtractMemories(): void {
  // Closure scope state:
  // - lastMemoryMessageUuid: cursor of last processed message
  // - inProgress: prevents duplicate execution
  // - turnsSinceLastExtraction: runs every N turns (tengu_bramble_lintel)
  // - pendingContext: waiting context when in progress (trailing run)
}
```

**Key characteristics:**
- Skips extraction if main agent has written memory directly (hasMemoryWritesSince)
- maxTurns: 5 (prevents excessive verification loops)
- Uses combined prompt when team memory is active
- Notifies main agent of extracted memory file count via `appendSystemMessage`
- Tool restrictions: Read/Grep/Glob (unlimited), read-only Bash, Edit/Write (auto-memory directory only)

### Layer 4: Team Memory Sync

[Detailed in Section 8]

### Layer 5: Auto-Dream

[Detailed in Section 9]

---

## 7. Memory Storage Paths

### 4 Scopes

```
User Scope    : ~/.claude/
Project Scope : .claude/ (committed to VCS)
Local Scope   : .claude/ (not committed to VCS)
Team Scope    : ~/.claude/projects/{slug}/memory/team/
```

### Path Resolution Priority

```typescript
// src/memdir/paths.ts

function getAutoMemPath(): string {
  // 1. CLAUDE_COWORK_MEMORY_PATH_OVERRIDE (Cowork SDK direct path)
  // 2. settings.json autoMemoryDirectory (policy/local/user, excludes project)
  // 3. {memoryBase}/projects/{sanitized-git-root}/memory/
}

function getMemoryBaseDir(): string {
  // 1. CLAUDE_CODE_REMOTE_MEMORY_DIR (CCR environment)
  // 2. ~/.claude (default)
}
```

### MEMORY.md Format

```markdown
---
name: {{memory name}}
description: {{one-line description}}
type: {{user, feedback, project, reference}}
---

{{memory content}}
```

### Limits

| Item | Value |
|------|-------|
| MEMORY.md max lines | 200 |
| MEMORY.md max size | 25KB |
| Recommended line length per entry | ~150 chars or less |

```typescript
// src/memdir/memdir.ts
export const MAX_ENTRYPOINT_LINES = 200
export const MAX_ENTRYPOINT_BYTES = 25_000
```

### Memory Type Taxonomy

```typescript
// src/memdir/memoryTypes.ts

const MEMORY_TYPES = ['user', 'feedback', 'project', 'reference'] as const

// user: user role, preferences, knowledge
// feedback: guidance on work approach (corrections + confirmations)
// project: project context not derivable from code/git
// reference: external system pointers (Linear, Grafana, etc.)
```

**Scope determination in team mode:**

| Type | Default Scope |
|------|---------------|
| user | always private |
| feedback | default private (team if project convention) |
| project | strongly bias toward team |
| reference | usually team |

### What Not to Store

- Code patterns, architecture, file paths (derivable from code)
- Git history, change logs (git log/blame is authoritative)
- Debugging solutions (context exists in commit messages)
- Content already documented in CLAUDE.md
- Temporary work state, current conversation context

### Kairos Mode (Assistant Daily Log)

```typescript
// Append-only daily log for long-running sessions
// Instead of MEMORY.md, adds timestamped bullets to logs/YYYY/MM/YYYY-MM-DD.md
// Separate nightly /dream skill refines logs into MEMORY.md + topic files
```

---

## 8. Team Memory Synchronization

### Architecture Overview

```
Local team dir                    Anthropic API
~/.claude/projects/               /api/claude_code/team_memory
  {slug}/memory/team/
         |                              |
    fs.watch (recursive)           OAuth-based
         |                              |
  debounced push ──── delta sync ────> PUT
  pull on startup <── ETag cache ────< GET
```

### API Schema

```typescript
// src/services/teamMemorySync/types.ts

type TeamMemoryData = {
  organizationId: string
  repo: string               // GitHub repo slug
  version: number
  lastModified: string       // ISO 8601
  checksum: string           // "sha256:..." prefix
  content: {
    entries: Record<string, string>     // Relative path -> content
    entryChecksums?: Record<string, string>  // Relative path -> sha256
  }
}
```

### Sync State

```typescript
// src/services/teamMemorySync/index.ts

type SyncState = {
  lastFetchChecksum?: string    // ETag caching
  serverChecksums: Record<string, string>  // Server-side entry hashes
  serverMaxEntries?: number     // Server limit (learned from 413 responses)
}
```

### Pull Flow

```
startTeamMemoryWatcher()
  -> createSyncState()
  -> pullTeamMemory(syncState)
       -> GET /api/claude_code/team_memory (ETag: lastFetchChecksum)
       -> 304: no changes
       -> 404: no data on server (isEmpty)
       -> 200: write entries to team dir + cache ETag
  -> startFileWatcher(teamDir)
```

### Push Flow

```
fs.watch event or notifyTeamMemoryWrite()
  -> schedulePush()  (2-second debounce)
  -> executePush()
       -> pushTeamMemory(syncState)
            -> Scan local files
            -> Calculate delta (serverChecksums vs local sha256)
            -> Secret scanning (PSR M22174)
            -> PUT /api/claude_code/team_memory (If-Match: checksum)
            -> 409: conflict -> re-fetch hashes and retry
            -> 412: precondition failed -> conflict resolution
            -> 413: too many entries -> cache server limit
```

### Secret Scanning

```typescript
// src/services/teamMemorySync/secretScanner.ts

// High-confidence subset of 30+ gitleaks rules
// GitHub PAT, AWS Access Token, Anthropic API Key, etc.

function scanForSecrets(content: string): SecretMatch[]
function redactSecrets(content: string): string

type SecretMatch = {
  ruleId: string  // e.g., "github-pat"
  label: string   // e.g., "GitHub PAT"
}
```

Files with detected secrets are excluded from push and reported as `skippedSecrets`. The secret values themselves are never logged.

### ETag Caching

- `lastFetchChecksum` stores the server ETag
- Sent via `If-None-Match` header on next GET
- 304 response means skip with zero network cost
- Each entry's `entryChecksums` enables delta push, transmitting only changed files

### 250KB Limit

Single entries exceeding 250KB per the server-side `MAX_FILE_SIZE_BYTES` are pre-rejected on the client. The `team_memory_too_many_entries` from 413 responses is cached in `serverMaxEntries` to pre-block subsequent pushes.

### Permanent Failure Suppression

```typescript
function isPermanentFailure(r: TeamMemorySyncPushResult): boolean {
  // no_oauth, no_repo: not resolvable via retry
  // 4xx (except 409/429): client error
  // -> Record in pushSuppressedReason to ignore watcher events
  // -> Suppression lifted on file deletion (unlink) events
}
```

### Security: Path Validation

```typescript
// src/memdir/teamMemPaths.ts

// Prevents escape from team memory directory
async function validateTeamMemWritePath(filePath: string): Promise<string>
async function validateTeamMemKey(relativeKey: string): Promise<string>

// Validation steps:
// 1. Reject null bytes
// 2. Normalize .. via path.resolve()
// 3. Verify teamDir prefix
// 4. Resolve symlinks via realpathDeepestExisting()
// 5. Verify real path is inside real teamDir
```

---

## 9. Auto-Dream Integration

### Trigger Conditions

```typescript
// src/services/autoDream/autoDream.ts

type AutoDreamConfig = {
  minHours: number     // default: 24
  minSessions: number  // default: 5
}

// Gate ordering (by cost):
// 1. Time: >= minHours since lastConsolidatedAt
// 2. Sessions: transcript count in period >= minSessions
// 3. Lock: no other process is consolidating
```

### Consolidation Lock

```typescript
// src/services/autoDream/consolidationLock.ts

// Lock file: {autoMemPath}/.consolidate-lock
// mtime = lastConsolidatedAt
// Body = holder PID

async function tryAcquireConsolidationLock(): Promise<number | null>
// Success: returns priorMtime (for rollback)
// Failure: null (another process holds it)
// Contention: write PID then re-read to determine winner

async function rollbackConsolidationLock(priorMtime: number): Promise<void>
// Reverts mtime to priorMtime (on failure, retry in next session)

// Scan throttle: scan sessions only every 10 minutes
const SESSION_SCAN_INTERVAL_MS = 10 * 60 * 1000
```

### DreamTask Lifecycle

```typescript
// src/tasks/DreamTask/DreamTask.ts

type DreamTaskState = TaskStateBase & {
  type: 'dream'
  phase: 'starting' | 'updating'
  sessionsReviewing: number
  filesTouched: string[]        // Paths observed from Edit/Write
  turns: DreamTurn[]            // Max 30 turns
  abortController?: AbortController
  priorMtime: number            // For lock rollback on kill
}

// Lifecycle:
// registerDreamTask() -> running/starting
// addDreamTurn() -> running/updating (on file changes)
// completeDreamTask() -> completed
// failDreamTask() -> failed (lock mtime rollback)
// DreamTask.kill() -> killed (AbortController.abort + lock rollback)
```

### Execution Flow

```
executeAutoDream(context)
  -> isGateOpen() check (kairos, remote, autoMem)
  -> readLastConsolidatedAt() -> time gate
  -> Scan throttle check
  -> listSessionsTouchedSince() -> session gate
  -> tryAcquireConsolidationLock() -> acquire lock
  -> registerDreamTask() -> display in UI
  -> buildConsolidationPrompt() -> 4-stage structure
  -> runForkedAgent({
       canUseTool: createAutoMemCanUseTool(),  // read-only Bash
       skipTranscript: true,
       onMessage: makeDreamProgressWatcher(),
     })
  -> completeDreamTask()
  -> appendSystemMessage("Improved N memories")
```

### Dream Prompt Structure

```
1. Orient: Survey current memory directory state
2. Gather: Extract key insights from recent session transcripts
3. Consolidate: Merge new information with existing memories
4. Prune: Clean up outdated or duplicate memories
```

---

## 10. Task System

### 7 Task Types

```typescript
// src/tasks/types.ts

type TaskState =
  | LocalShellTaskState          // Local shell command (background Bash)
  | LocalAgentTaskState          // Local agent (Agent tool)
  | RemoteAgentTaskState         // Remote agent (CCR)
  | InProcessTeammateTaskState   // In-process teammate
  | LocalWorkflowTaskState       // Workflow (unused/reserved)
  | MonitorMcpTaskState          // MCP server monitoring
  | DreamTaskState               // Auto-dream consolidation
```

### Common Base State

```typescript
// Inferred from src/Task.ts

type TaskStateBase = {
  id: string
  type: string
  status: 'pending' | 'running' | 'completed' | 'failed' | 'killed'
  description: string
  startTime: number
  endTime?: number
  isBackgrounded?: boolean
  notified?: boolean           // Whether coordinator has been notified
  retain?: boolean             // Whether to retain messages
}
```

### LocalAgentTaskState (Core)

```typescript
// Inferred from src/tasks/LocalAgentTask/LocalAgentTask.tsx

type LocalAgentTaskState = TaskStateBase & {
  type: 'local_agent'
  agentId: string
  agentType: string
  prompt: string
  selectedAgent?: AgentDefinition
  abortController?: AbortController
  progress?: AgentProgress
  messages?: MessageType[]          // When retain=true
  pendingMessages?: string[]        // SendMessage queue
  result?: AgentToolResult
}

type AgentProgress = {
  toolUseCount: number
  tokenCount: number
  lastActivity?: {
    activityDescription: string
  }
}
```

### InProcessTeammateTaskState

```typescript
// src/tasks/InProcessTeammateTask/types.ts

type InProcessTeammateTaskState = TaskStateBase & {
  type: 'in_process_teammate'
  identity: TeammateIdentity
  prompt: string
  model?: string
  selectedAgent?: AgentDefinition
  abortController?: AbortController
  currentWorkAbortController?: AbortController
  awaitingPlanApproval: boolean
  permissionMode: PermissionMode
  error?: string
  result?: AgentToolResult
  progress?: AgentProgress
  messages?: Message[]              // For UI display (max 50)
  inProgressToolUseIDs?: Set<string>
  pendingUserMessages: string[]
  isIdle: boolean
  shutdownRequested: boolean
  onIdleCallbacks?: Array<() => void>
  lastReportedToolCount: number
  lastReportedTokenCount: number
  spinnerVerb?: string
  pastTenseVerb?: string
}

// Message UI cap: memory optimization
const TEAMMATE_MESSAGES_UI_CAP = 50
```

### DreamTaskState

```typescript
type DreamTaskState = TaskStateBase & {
  type: 'dream'
  phase: 'starting' | 'updating'
  sessionsReviewing: number
  filesTouched: string[]
  turns: DreamTurn[]           // Max 30 turns
  abortController?: AbortController
  priorMtime: number
}
```

### Background Task Identification

```typescript
function isBackgroundTask(task: TaskState): boolean {
  if (task.status !== 'running' && task.status !== 'pending') return false
  if ('isBackgrounded' in task && task.isBackgrounded === false) return false
  return true
}
```

### Task Registration and State Management

```typescript
// Provided by src/utils/task/framework.ts

function registerTask(task: TaskState, setAppState: SetAppState): void
function updateTaskState<T extends TaskState>(
  taskId: string,
  setAppState: SetAppState,
  updater: (prev: T) => T,
): void
```

### Eviction Rules

- Tasks with `notified: true` in terminal state (completed/failed/killed) are eviction candidates
- DreamTask has no model-facing notification path, so `notified: true` is set immediately on completion
- Background task indicator only shows running/pending tasks

### Task-to-Tool Relationships

| Task Type | Creating Tool/Service |
|-----------|----------------------|
| LocalShell | BashTool (background) |
| LocalAgent | AgentTool |
| RemoteAgent | AgentTool (isolation: 'remote') |
| InProcessTeammate | TeamCreateTool + AgentTool (in-process) |
| Dream | autoDream service |
| Workflow | (reserved) |
| MonitorMcp | MCP server connection monitoring |

---

## Appendix: Core TypeScript Interface Summary

```typescript
// === Agent Definitions ===
type BaseAgentDefinition = {
  agentType: string
  whenToUse: string
  tools?: string[]
  disallowedTools?: string[]
  skills?: string[]
  mcpServers?: AgentMcpServerSpec[]
  hooks?: HooksSettings
  color?: AgentColorName
  model?: string
  effort?: EffortValue
  permissionMode?: PermissionMode
  maxTurns?: number
  background?: boolean
  initialPrompt?: string
  memory?: AgentMemoryScope
  isolation?: 'worktree' | 'remote'
  omitClaudeMd?: boolean
}

type BuiltInAgentDefinition = BaseAgentDefinition & {
  source: 'built-in'
  getSystemPrompt: (params: { toolUseContext: Pick<ToolUseContext, 'options'> }) => string
}

type CustomAgentDefinition = BaseAgentDefinition & {
  source: SettingSource
  getSystemPrompt: () => string
}

type PluginAgentDefinition = BaseAgentDefinition & {
  source: 'plugin'
  getSystemPrompt: () => string
  plugin: string
}

// === Swarm ===
type TeamFile = {
  name: string
  description?: string
  createdAt: number
  leadAgentId: string
  leadSessionId?: string
  hiddenPaneIds?: string[]
  teamAllowedPaths?: TeamAllowedPath[]
  members: Array<TeamMember>
}

type TeammateExecutor = {
  readonly type: BackendType
  isAvailable(): Promise<boolean>
  spawn(config: TeammateSpawnConfig): Promise<TeammateSpawnResult>
  sendMessage(agentId: string, message: TeammateMessage): Promise<void>
  terminate(agentId: string, reason?: string): Promise<boolean>
  kill(agentId: string): Promise<boolean>
  isActive(agentId: string): Promise<boolean>
}

type PaneBackend = {
  readonly type: BackendType
  readonly displayName: string
  readonly supportsHideShow: boolean
  isAvailable(): Promise<boolean>
  isRunningInside(): Promise<boolean>
  createTeammatePaneInSwarmView(name: string, color: AgentColorName): Promise<CreatePaneResult>
  sendCommandToPane(paneId: PaneId, command: string): Promise<void>
  setPaneBorderColor(paneId: PaneId, color: AgentColorName): Promise<void>
  setPaneTitle(paneId: PaneId, name: string, color: AgentColorName): Promise<void>
  killPane(paneId: PaneId): Promise<boolean>
  hidePane(paneId: PaneId): Promise<boolean>
  showPane(paneId: PaneId, targetWindowOrPane: string): Promise<boolean>
}

// === Permission Synchronization ===
type SwarmPermissionRequest = {
  id: string
  workerId: string
  workerName: string
  workerColor?: string
  teamName: string
  toolName: string
  toolUseId: string
  description: string
  input: Record<string, unknown>
  permissionSuggestions: unknown[]
  status: 'pending' | 'approved' | 'rejected'
  resolvedBy?: 'worker' | 'leader'
  resolvedAt?: number
  feedback?: string
  updatedInput?: Record<string, unknown>
  permissionUpdates?: unknown[]
  createdAt: number
}

type PermissionResolution = {
  decision: 'approved' | 'rejected'
  resolvedBy: 'worker' | 'leader'
  feedback?: string
  updatedInput?: Record<string, unknown>
  permissionUpdates?: PermissionUpdate[]
}

// === Memory ===
type MemoryType = 'user' | 'feedback' | 'project' | 'reference'
type AgentMemoryScope = 'user' | 'project' | 'local'

type TeamMemoryData = {
  organizationId: string
  repo: string
  version: number
  lastModified: string
  checksum: string
  content: {
    entries: Record<string, string>
    entryChecksums?: Record<string, string>
  }
}

// === Tasks ===
type TaskState =
  | LocalShellTaskState
  | LocalAgentTaskState
  | RemoteAgentTaskState
  | InProcessTeammateTaskState
  | LocalWorkflowTaskState
  | MonitorMcpTaskState
  | DreamTaskState
```

---

## Implementation Caveats

### C1. Fork Abort Non-Propagation
When the parent agent is aborted, the fork child's `AbortController` is **not automatically triggered**. If parent-child abort propagation is needed, use the `shutdown_request` protocol via `SendMessage`.

### C2. Worktree Cleanup Not Guaranteed
When an `isolation: 'worktree'` agent crashes or is killed, the worktree persists. Auto-cleanup only occurs on (a) normal completion with no changes, (b) SessionMemory cleanup at session end, (c) manual CleanupTool. Periodic cleanup is required.

### C3. Team Memory Concurrent Write — No Locking
`writeFile()` has no file locking. If two sessions pull simultaneously, the last writer wins with undefined ordering. Only server-side ETag-based conflict detection (412) exists; local file writes are unprotected.

### C4. setAppStateForTasks Async Propagation
`setAppStateForTasks()` is asynchronous and does not automatically propagate to new child agents. Children receive a state snapshot at spawn time. Subsequent parent state changes are not reflected in children.

### C5. Memory Read Priority
When the same key exists in multiple layers: session > project > user > team > global (higher takes priority). This priority must be explicitly implemented.

### C6. SendMessage — Terminated Agents
When the target agent has already terminated, SendMessage returns an error after a 30-second timeout on mailbox file reading. There is no mechanism to pre-check agent status.
