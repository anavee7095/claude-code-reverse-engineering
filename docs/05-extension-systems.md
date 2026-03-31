# Part 5: Extension Systems

> Reverse engineering design document for the Claude Code CLI extension systems. Covers implementation-level specifications for MCP integration, plugin system, skill system, hook system, LSP integration, and bridge system.

---

## Table of Contents

1. [MCP Integration](#1-mcp-integration)
2. [Plugin System](#2-plugin-system)
3. [Skill System](#3-skill-system)
4. [Hook System](#4-hook-system)
5. [LSP Integration](#5-lsp-integration)
6. [Bridge System](#6-bridge-system)
7. [Extension System Synthesis](#7-extension-system-synthesis)

---

## 1. MCP Integration

### 1.1 Architecture Overview

MCP(Model Context Protocol) integration is the core mechanism for Claude Code to communicate with external tool servers. `src/services/mcp/` directory, including multi- Transport, OAuth authentication, dynamic tool schemas, and server state management.

**Key files:**
- `client.ts` (3,348 lines) - Server connection, tool invocation, result processing
- `config.ts` (1,578 lines) - Config loading, Policy Enforcement, Environment variable expansion
- `auth.ts` (2,465 lines) - OAuth flow, XAA, Token management
- `types.ts` - All MCP-related type definitions

### 1.2 Transport Types

Transports are classified into two levels:

- **`TransportSchema`** (`src/services/mcp/types.ts`): `'stdio' | 'sse' | 'sse-ide' | 'http' | 'ws' | 'sdk'` — **6** (Zod literal union)
- **`McpServerConfig` union**: TransportSchema 6 + `ws-ide` + `claudeai-proxy` = **8 config types**

```typescript
// TransportSchema — src/services/mcp/types.ts (only includes 6)
type TransportType = 'stdio' | 'sse' | 'sse-ide' | 'http' | 'ws' | 'sdk'
// Note: ws-ide exists as a separate variant in the McpServerConfig union (not included in TransportSchema)
// claudeai-proxy is internal only, managed separately from both
```

#### StdIO Transport
```typescript
// McpStdioServerConfigSchema
{
  type?: 'stdio',        // Optional (Backward compatibility, Default)
  command: string,       // Command to execute (Required, must not be empty)
  args: string[],        // Command arguments (Default: [])
  env?: Record<string, string>  // Environment variable overrides
}
```
- Uses `StdioClientTransport` (MCP SDK)
- Inherits default environment variables via `subprocessEnv()`
- JSON-RPC communication via child process stdin/stdout

#### SSE Transport
```typescript
// McpSSEServerConfigSchema
{
  type: 'sse',
  url: string,
  headers?: Record<string, string>,
  headersHelper?: string,    // Dynamic header generation script
  oauth?: {
    clientId?: string,
    callbackPort?: number,
    authServerMetadataUrl?: string,  // HTTPS Required
    xaa?: boolean                     // Enable Cross-App Access
  }
}
```
- Uses `SSEClientTransport` (MCP SDK)
- EventSource GET has no timeout (long-lived connection)
- 60-second timeout applied only to POST requests

#### HTTP Streamable Transport
```typescript
// McpHTTPServerConfigSchema
{
  type: 'http',
  url: string,
  headers?: Record<string, string>,
  headersHelper?: string,
  oauth?: McpOAuthConfig
}
```
- Uses `StreamableHTTPClientTransport` (MCP SDK)
- MCP Streamable HTTP spec compliant: `Accept: application/json, text/event-stream` Required

#### WebSocket Transport
```typescript
// McpWebSocketServerConfigSchema
{
  type: 'ws',
  url: string,
  headers?: Record<string, string>,
  headersHelper?: string
}
```
- Uses custom `WebSocketTransport`
- Utilizing `ws` package's 3-arg constructor (protocol: `['mcp']`)
- mTLS support (`getWebSocketTLSOptions`)

#### SSE-IDE Transport (Internal only)
```typescript
// McpSSEIDEServerConfigSchema
{
  type: 'sse-ide',
  url: string,
  ideName: string,
  ideRunningInWindows?: boolean
}
```
- IDE extension exclusive, no authentication required
- Allowed tool whitelist: `mcp__ide__executeCode`, `mcp__ide__getDiagnostics`

#### WS-IDE Transport (Internal only)
```typescript
// McpWSIDEServerConfigSchema
{
  type: 'ws-ide',
  url: string,
  ideName: string,
  authToken?: string,               // WebSocket authentication token
  ideRunningInWindows?: boolean
}
```
- WebSocket version of SSE-IDE (VS Code internal communication)
- IDE extension exclusive, same as SSE-IDE
- Optional authentication via `authToken`

#### SDK Transport
```typescript
// McpSdkServerConfigSchema
{
  type: 'sdk',
  name: string
}
```
- Uses `SdkControlClientTransport`
- SDK-managed transport placeholder (CLI does not create process/connection)
- Tool calls are routed to SDK

#### Claude.ai Proxy (Internal only)
```typescript
// McpClaudeAIProxyServerConfigSchema
{
  type: 'claudeai-proxy',
  url: string,
  id: string
}
```
- Proxy for claude.ai connector
- OAuth Bearer token automatically attached
- 1 automatic retry on 401 (token refresh)

### 1.3 Server State Machine

MCP servers have 5 states:

```
                    ┌──────────┐
          ┌────────►│ Connected │◄───────────────┐
          │         └──────────┘                  │
          │              │                        │
     Connection success      Tool call 401            Reconnection success
          │              │                        │
          │              ▼                        │
    ┌─────────┐   ┌────────────┐           ┌─────────┐
    │ Pending │   │ NeedsAuth  │           │ Failed  │
    └─────────┘   └────────────┘           └─────────┘
          │              │                      ▲
          │         Auth failed                    │
          │              │                 Connection failed
          │              ▼                      │
          │         ┌──────────┐                │
          └────────►│ Disabled │────────────────┘
                    └──────────┘
```

```typescript
type MCPServerConnection =
  | ConnectedMCPServer    // Connected - holds client, capabilities, cleanup
  | FailedMCPServer       // Failed - holds error message
  | NeedsAuthMCPServer    // Auth needed - awaiting OAuth flow
  | PendingMCPServer      // Pending - tracking reconnectAttempt
  | DisabledMCPServer     // Disabled - by user or policy

// Full structure of ConnectedMCPServer:
type ConnectedMCPServer = {
  client: Client              // MCP SDK Client instance
  name: string
  type: 'connected'
  capabilities: ServerCapabilities
  serverInfo?: { name: string; version: string }
  instructions?: string       // Usage instructions provided by server
  config: ScopedMcpServerConfig
  cleanup: () => Promise<void>
}
```

### 1.3.1 Reconnection Strategy

```typescript
// src/services/mcp/client.ts:1225-1228
// SDK Transport only calls onerror without calling onclose
// → CC manually tracks via consecutiveConnectionErrors

const MAX_ERRORS_BEFORE_RECONNECT = 3

// Consecutive connection error tracking:
//   1. Only counts errors where isTransportConnectionError() = true
//      (ECONNREFUSED, Body Timeout, terminated, SSE stream disconnected, etc.)
//   2. After 3 consecutive → closeTransportAndRejectPending() → client.close()
//      → All pending callTool() Promises rejected (-32000)
//      → client.onclose handler invalidates memoization cache
//      → Auto-reconnects on next call

// HTTP Transport: Session expiry detection (404 + JSON-RPC -32001)
//   → Close transport → Reconnect

// StreamableHTTP (including claudeai-proxy):
//   → SDK internal SSE reconnection attempt (maxRetries: 2)
//   → On failure: "Maximum reconnection attempts" error → Close transport

// 401 authentication error:
//   → 1 token refresh then retry (claudeai-proxy only)
```

### 1.4 Config Scopes

7 config scopes exist, merged by priority:

```typescript
type ConfigScope = 'local' | 'user' | 'project' | 'dynamic' | 'enterprise' | 'claudeai' | 'managed'
```

| Scope | Location | Description |
|--------|------|------|
| `local` | `.claude/settings.local.json` | Local project settings (gitignore) |
| `user` | `~/.claude/settings.json` | User global settings |
| `project` | `.mcp.json` | Project MCP settings (git tracked) |
| `dynamic` | Runtime injection | Dynamically injected via SDK/CLI flags |
| `enterprise` | `managed-mcp.json` | Enterprise managed settings |
| `claudeai` | Remote API | claude.ai connector |
| `managed` | `getManagedFilePath()` | Managed settings path |

**Config merge order:**
```
enterprise (highest priority, exclusive)
  ↓
claudeai servers (remote fetch)
  ↓
plugin MCP servers (deduplicated via dedupPluginMcpServers)
  ↓
local → user → project (getClaudeCodeMcpConfigs merge)
```

**Deduplication mechanism:**
```typescript
// Duplicate detection via server signature
function getMcpServerSignature(config: McpServerConfig): string | null {
  // stdio: JSON-serialized [command, ...args]
  // remote: unwrapCcrProxyUrl(url)
  // sdk: null (exempt from deduplication)
}
```

### 1.5 Policy Enforcement

**Allow/block lists:**
```typescript
// Block list takes absolute precedence
function isMcpServerAllowedByPolicy(name, config): boolean {
  if (isMcpServerDenied(name, config)) return false  // Block always takes precedence
  // If allowedMcpServers is not set, allow all
  // Otherwise, match by name/command/URL pattern
}

// 3 matching modes:
// 1. Name-based: { serverName: "my-server" }
// 2. Command-based: { serverCommand: ["npx", "mcp-server"] }
// 3. URL-based: { serverUrl: "https://*.example.com/*" }  // Wildcard support
```

### 1.6 OAuth/XAA Authentication

**ClaudeAuthProvider class:**
```typescript
class ClaudeAuthProvider implements OAuthClientProvider {
  // Token storage: secure storage (macOS keychain / credentials file)
  // Client information: File-based cache + lock file
  // Includes PKCE code verifier

  async tokens(): Promise<OAuthTokens | undefined>
  async saveTokens(tokens: OAuthTokens): Promise<void>
  async redirectUrl(): Promise<URL>  // Local callback server
  async clientInformation(): Promise<OAuthClientInformation>
  async saveClientInformation(info: OAuthClientInformationFull): Promise<void>
}
```

**XAA (Cross-App Access, SEP-990):**
- Enabled per server via `xaa: boolean` flag
- IdP configuration (`settings.xaaIdp`) is configured globally once
- `acquireIdpIdToken()` → `performCrossAppAccess()` → MCP server AS token exchange

**OAuth error normalization:**
```typescript
// Converts non-standard error codes (e.g., Slack) to RFC 6749 standard
const NONSTANDARD_INVALID_GRANT_ALIASES = new Set([
  'invalid_refresh_token',
  'expired_refresh_token',
  'token_expired',
])
// → All normalized to 'invalid_grant'
```

### 1.7 Tool Creation and Invocation

**MCPTool structure:**
```typescript
// src/tools/MCPTool/MCPTool.ts
const MCPTool = buildTool({
  isMcp: true,
  name: 'mcp',                    // Overridden with actual name in client.ts
  inputSchema: z.object({}).passthrough(), // MCP server defines its own schema
  maxResultSizeChars: 100_000,

  async call() { /* Overridden in client.ts */ },
  async description() { /* Overridden in client.ts */ },
  async prompt() { /* Overridden in client.ts */ },

  checkPermissions() {
    return { behavior: 'passthrough', message: 'MCPTool requires permission.' }
  },
})
```

**Tool naming convention:**
```
mcp__{serverName}__{toolName}
```
- Normalized via `normalizeNameForMCP()`
- Combined via `buildMcpToolName()`
- Maintains reverse mapping of original names via `normalizedNames` map

**Tool description length limit:**
```typescript
const MAX_MCP_DESCRIPTION_LENGTH = 2048  // p95 tail limit
```

**Tool call timeout:**
```typescript
const DEFAULT_MCP_TOOL_TIMEOUT_MS = 100_000_000  // ~27.8 hours (effectively unlimited)
// Can be overridden via MCP_TOOL_TIMEOUT environment variable
```

### 1.8 Connection Management

**Batch connection:**
```typescript
function getMcpServerConnectionBatchSize(): number {
  // MCP_SERVER_CONNECTION_BATCH_SIZE environment variable, Default 3 (local servers)
}
function getRemoteMcpServerConnectionBatchSize(): number {
  // MCP_REMOTE_SERVER_CONNECTION_BATCH_SIZE, Default 20 (remote servers)
}
```

**Connection cache:**
```typescript
// Cached via memoize, cache key = `${name}-${JSON.stringify(config)}`
export const connectToServer = memoize(async (name, serverRef) => { ... })
```

**Session expiry detection:**
```typescript
// Determined as session expired when both HTTP 404 + JSON-RPC -32001 code are met
function isMcpSessionExpiredError(error: Error): boolean {
  return error.code === 404 &&
    (error.message.includes('"code":-32001') ||
     error.message.includes('"code": -32001'))
}
```

**Auth-needed cache:**
```typescript
const MCP_AUTH_CACHE_TTL_MS = 15 * 60 * 1000  // 15 minutes
// Caches needs-auth state to file to prevent unnecessary connection attempts across restarts
```

### 1.9 MCP Server Config Schema (Complete)

```typescript
// McpServerConfig union type
type McpServerConfig =
  | { type?: 'stdio'; command: string; args: string[]; env?: Record<string, string> }
  | { type: 'sse'; url: string; headers?: Record<string, string>; headersHelper?: string; oauth?: McpOAuthConfig }
  | { type: 'sse-ide'; url: string; ideName: string; ideRunningInWindows?: boolean }
  | { type: 'ws-ide'; url: string; ideName: string; authToken?: string; ideRunningInWindows?: boolean }
  | { type: 'http'; url: string; headers?: Record<string, string>; headersHelper?: string; oauth?: McpOAuthConfig }
  | { type: 'ws'; url: string; headers?: Record<string, string>; headersHelper?: string }
  | { type: 'sdk'; name: string }
  | { type: 'claudeai-proxy'; url: string; id: string }

type McpOAuthConfig = {
  clientId?: string
  callbackPort?: number
  authServerMetadataUrl?: string  // HTTPS Required
  xaa?: boolean                    // Cross-App Access
}

type ScopedMcpServerConfig = McpServerConfig & {
  scope: ConfigScope
  pluginSource?: string  // LoadedPlugin.source of the providing plugin
}

// .mcp.json file format
type McpJsonConfig = {
  mcpServers: Record<string, McpServerConfig>
}
```

---

## 2. Plugin System

### 2.1 Architecture Overview

The Plugin System is the core mechanism for extending Claude Code, capable of providing tools, commands, hooks, agents, MCP servers, and LSP servers.

**Key files:**
- `src/utils/plugins/pluginLoader.ts` (3,302 lines) - Discovery, validation, loading
- `src/utils/plugins/marketplaceManager.ts` (2,643 lines) - Marketplace management
- `src/utils/plugins/schemas.ts` - All plugin schema definitions
- `src/plugins/builtinPlugins.ts` - Built-in plugins registry

### 2.2 Plugin Manifest (plugin.json)

```typescript
// PluginManifestSchema - complete plugin.json schema
{
  // === Metadata ===
  name: string,              // Unique identifier, kebab-case, no spaces
  version?: string,          // Semantic version (semver.org)
  description?: string,      // User-facing description
  author?: {
    name: string,            // Author name (Required)
    email?: string,
    url?: string
  },
  homepage?: string,         // URL
  repository?: string,       // Source code URL
  license?: string,          // SPDX identifier
  keywords?: string[],       // Tags for search/classification
  dependencies?: string[],   // Required plugins ("name@marketplace" or "name")

  // === Extension Points ===
  hooks?: string | HooksSettings | (string | HooksSettings)[],
  commands?: string | string[] | Record<string, CommandMetadata>,
  agents?: string | string[],
  skills?: string | string[],
  outputStyles?: string | string[],
  mcpServers?: string | McpbPath | Record<string, McpServerConfig>
              | (string | McpbPath | Record<string, McpServerConfig>)[],
  lspServers?: string | Record<string, LspServerConfig>
              | (string | Record<string, LspServerConfig>)[],

  // === Channels (Assistant Mode) ===
  channels?: Array<{
    server: string,          // Matches key in mcpServers
    displayName?: string,
    userConfig?: Record<string, UserConfigOption>
  }>,

  // === User Configuration ===
  userConfig?: Record<string, {
    type: 'string' | 'number' | 'boolean' | 'directory' | 'file',
    title: string,           // Settings dialog label
    description: string,     // Help text
    required?: boolean,
    default?: string | number | boolean | string[],
    multiple?: boolean,      // string type: allow arrays
    sensitive?: boolean,     // true: stored in keychain, input masked
    min?: number,            // number type only
    max?: number
  }>,

  // === Settings Merge ===
  settings?: Record<string, unknown>  // Only allowed keys retained (currently: agent)
}
```

**CommandMetadata schema:**
```typescript
type CommandMetadata = {
  source?: string,       // Markdown file path (relative)
  content?: string,      // Inline markdown content
  // Exactly one of source or content must be specified
  description?: string,  // Command description override
  argumentHint?: string, // Argument hint (e.g., "[file]")
  model?: string,        // Default model
  allowedTools?: string[] // Allowed tool list
}
```

### 2.3 Plugin Directory Structure

```
my-plugin/
├── plugin.json              # Manifest (optional)
├── .mcp.json                # MCP server config
├── commands/                # Slash commands
│   ├── build.md             # /plugin:build
│   └── deploy.md            # /plugin:deploy
├── agents/                  # AI agents
│   └── test-runner.md
├── skills/                  # Skills directory
│   └── my-skill/
│       └── SKILL.md
├── hooks/                   # Hook config
│   └── hooks.json
├── output-styles/           # Output styles
│   └── custom-style.md
└── .lsp.json                # LSP server config
```

### 2.4 Marketplace Model

**Marketplace source types:**
```typescript
type MarketplaceSource =
  | { source: 'url'; url: string; headers?: Record<string, string> }
  | { source: 'github'; repo: string; ref?: string; path?: string; sparsePaths?: string[] }
  | { source: 'git'; url: string; ref?: string; path?: string; sparsePaths?: string[] }
  | { source: 'npm'; package: string }
  | { source: 'file'; path: string }
  | { source: 'directory'; path: string }
  | { source: 'hostPattern'; hostPattern: string }    // Regex for allowlist
  | { source: 'pathPattern'; pathPattern: string }     // Regex for allowlist
  | { source: 'settings'; name: string; plugins: PluginEntry[]; owner?: Author }
```

**File structure:**
```
~/.claude/
└── plugins/
    ├── known_marketplaces.json        # Marketplace list
    ├── cache/                         # Plugin cache
    │   └── {marketplace}/{plugin}/{version}/
    └── marketplaces/                  # Marketplace cache
        ├── my-marketplace.json        # URL source: cached JSON
        └── github-marketplace/        # GitHub source: cloned repository
            └── .claude-plugin/
                └── marketplace.json
```

**Version caching:**
```typescript
// Version-specific cache path
function getVersionedCachePath(pluginId: string, version: string): string {
  // ~/.claude/plugins/cache/{marketplace}/{plugin}/{version}/
  // Each segment is sanitized (prevents path traversal)
}

// ZIP cache mode (optional optimization)
function getVersionedZipCachePath(pluginId: string, version: string): string {
  return `${getVersionedCachePath(pluginId, version)}.zip`
}
```

**Seed directories:**
- Seed cache locations queried via `getPluginSeedDirs()`
- Immediate loading from seed on first boot (without network)
- Searched in priority order, returns first match

### 2.5 Plugin Lifecycle

```
Discovery → Validation → Loading → Execution
   ↓            ↓           ↓          ↓
Marketplace  Manifest     Dependency  Tools/hooks/skills
config scan  schema check resolution  registration & activation
```

**Step 1: Discovery**
```typescript
// Discovery sources (by priority)
// 1. Marketplace-based ("plugin@marketplace" format)
// 2. Session-only (--plugin-dir CLI flag or SDK plugins option)
// 3. Built-in plugins ("plugin@builtin")
```

**Step 2: Validation**
```typescript
// Validate manifest with PluginManifestSchema
// Validate identifier with PluginIdSchema: "name@marketplace"
// Prevent impersonation of official marketplace names (BLOCKED_OFFICIAL_NAME_PATTERN)
// Block non-ASCII characters (homograph attack prevention)
```

**Step 3: Loading**
```typescript
type LoadedPlugin = {
  name: string
  manifest: PluginManifest
  path: string              // Filesystem path (sentinel for builtin)
  source: string            // "name@marketplace"
  repository: string
  enabled: boolean
  isBuiltin: boolean
  hooksConfig?: HooksSettings
  mcpServers?: Record<string, McpServerConfig>
}
```

**Step 4: Execution**
- Tools: Wrapped as MCPTool and exposed to LLM
- Hooks: Executed by `hooks.ts` when events fire
- Skills: Callable via SkillTool
- Commands: Registered in `/plugin:command` format

### 2.6 Built-in Plugins

```typescript
type BuiltinPluginDefinition = {
  name: string
  description: string
  version?: string
  skills?: BundledSkillDefinition[]
  hooks?: HooksSettings
  mcpServers?: Record<string, McpServerConfig>
  isAvailable?: () => boolean    // System availability check
  defaultEnabled?: boolean       // Default enabled state (Default: true)
}

// Registration
registerBuiltinPlugin(definition)

// Identifier: "name@builtin"
// Users can enable/disable via /plugin UI
// Settings stored in enabledPlugins[pluginId]
```

### 2.7 Policy Enforcement

**Marketplace restrictions:**
```typescript
// Reserved official marketplace names
const ALLOWED_OFFICIAL_MARKETPLACE_NAMES = new Set([
  'claude-code-marketplace', 'claude-code-plugins',
  'claude-plugins-official', 'anthropic-marketplace',
  'anthropic-plugins', 'agent-skills',
  'life-sciences', 'knowledge-work-plugins',
])

// Official names can only be used from Anthropic's GitHub org
function validateOfficialNameSource(name, source): string | null

// strictKnownMarketplaces: Only load from allowed marketplaces
// blockedMarketplaces: Block specific marketplaces
// pluginOnly policy: Only plugins allowed (direct MCP addition blocked)
```

**Plugin MCP server deduplication:**
```typescript
// Priority: manual config > plugins > claude.ai connector
function dedupPluginMcpServers(pluginServers, manualServers): {
  servers: Record<string, ScopedMcpServerConfig>
  suppressed: Array<{ name: string; duplicateOf: string }>
}
```

---

## 3. Skill System

### 3.1 Architecture Overview

Skills are special prompt commands that can be invoked by the LLM. They are divided into bundled skills, disk-based skills, plugin skills, and MCP skills.

**Key files:**
- `src/skills/bundledSkills.ts` - BundledSkillDefinition type and registration
- `src/skills/bundled/index.ts` - Bundled skill initialization
- `src/tools/SkillTool/SkillTool.ts` - SkillTool tool implementation

### 3.2 BundledSkillDefinition Type

```typescript
type BundledSkillDefinition = {
  name: string                    // Skill name (Registered as slash command)
  description: string             // User-facing description
  aliases?: string[]              // Alternative names
  whenToUse?: string              // Guidance for LLM on when to use
  argumentHint?: string           // Argument hint (e.g., "[file]")
  allowedTools?: string[]         // Allowed tools during skill execution
  model?: string                  // Model override
  disableModelInvocation?: boolean // Disable model invocation
  userInvocable?: boolean         // User directly invocable (Default: true)
  isEnabled?: () => boolean       // Dynamic enablement condition
  hooks?: HooksSettings           // Skill-specific hooks
  context?: 'inline' | 'fork'     // Execution context
  agent?: string                  // Agent type

  // Reference files (extracted to disk)
  files?: Record<string, string>  // { "relative-path": "content" }

  // Prompt generation function
  getPromptForCommand: (
    args: string,
    context: ToolUseContext
  ) => Promise<ContentBlockParam[]>
}
```

### 3.3 Bundled Skill List

Initialized in `src/skills/bundled/index.ts`:

| Skill | File | Feature Gate | Description |
|------|------|------------|------|
| `update-config` | `updateConfig.ts` | None (always registered) | Configuration setup |
| `keybindings-help` | `keybindings.ts` | None | Keybinding configuration |
| `verify` | `verify.ts` | None | Implementation verification |
| `debug` | `debug.ts` | None | Debugging helper |
| `lorem-ipsum` | `loremIpsum.ts` | None | Test text |
| `skillify` | `skillify.ts` | None | Skill creation helper |
| `remember` | `remember.ts` | None | Information recall |
| `simplify` | `simplify.ts` | None | Code simplification |
| `batch` | `batch.ts` | None | Batch processing |
| `stuck` | `stuck.ts` | None | Stuck situation helper |
| **`dream`** | `dream.ts` | **`KAIROS` or `KAIROS_DREAM`** | KAIROS dream mode — proactively executes tasks on behalf of user when idle (hidden skill) |
| **`hunter`** | `hunter.ts` | **`REVIEW_ARTIFACT`** | Artifact review (hidden skill) |
| `loop` | `loop.ts` | `AGENT_TRIGGERS` | Recurring execution (isEnabled delegates to isKairosCronEnabled()) |
| `schedule` | `scheduleRemoteAgents.ts` | `AGENT_TRIGGERS_REMOTE` | Remote agent scheduling |
| `claude-api` | `claudeApi.ts` | `BUILDING_CLAUDE_APPS` | Claude API helper |
| `claude-in-chrome` | `claudeInChrome.ts` | `shouldAutoEnableClaudeInChrome()` | Chrome integration (conditional) |
| **`run-skill-generator`** | `runSkillGenerator.ts` | **`RUN_SKILL_GENERATOR`** | Automatic skill generator (hidden skill) |

> **3 hidden skills**: `dream`, `hunter`, and `run-skill-generator` are only registered in builds where their respective feature flags `KAIROS/KAIROS_DREAM`, `REVIEW_ARTIFACT`, and `RUN_SKILL_GENERATOR` are enabled. In public builds, they are removed from the bundle via dead code elimination (DCE).

### 3.4 Skill Registration Mechanism

```typescript
// Bundled skill registration
function registerBundledSkill(definition: BundledSkillDefinition): void {
  // 1. If files exist, set up reference file extraction directory
  // 2. Wrap getPromptForCommand to prepend baseDir
  // 3. Convert to Command object and add to registry
}

// Property mapping when converting to Command:
const command: Command = {
  type: 'prompt',
  name: definition.name,
  source: 'bundled',         // Not 'builtin' (builtin = /help, /clear, etc.)
  loadedFrom: 'bundled',
  contentLength: 0,
  progressMessage: 'running',
  // ...remaining property mappings
}
```

### 3.5 Disk-Based Skills

Disk-based skills are files in YAML frontmatter + markdown format:

```markdown
---
name: my-skill
description: Does something useful
whenToUse: When user asks to do something
allowedTools:
  - Read
  - Write
  - Bash
model: claude-sonnet-4-6
---

# Skill Prompt

This skill performs the following...

Use the $ARGUMENTS variable to reference user input.
```

**Skill directory structure:**
```
my-skill/
├── SKILL.md          # Main skill file (frontmatter + prompt)
└── reference.ts      # Reference files (accessible via Read/Grep)
```

**Frontmatter parsing:**
```typescript
// src/utils/frontmatterParser.ts
function parseFrontmatter(content: string): {
  frontmatter: Record<string, unknown>
  body: string
}
```

### 3.6 SkillTool Invocation Mechanism

```typescript
// src/tools/SkillTool/SkillTool.ts
const SkillTool = buildTool({
  name: 'Skill',

  async call(input: { skill: string; args?: string }, context) {
    // 1. Collect all commands via getAllCommands() (local + MCP skills)
    // 2. Search for skill via findCommand()
    // 3. Determine execution method based on context:
    //    - 'fork': executeForkedSkill() - isolated subagent
    //    - 'inline': prompt injection in current context
    // 4. Return result
  }
})
```

**Fork execution:**
```typescript
async function executeForkedSkill(command, commandName, args, context, ...): Promise<ToolResult> {
  // 1. Generate new agentId
  // 2. Prepare isolated context via prepareForkedCommandContext()
  // 3. Execute subagent via runAgent()
  // 4. Extract result via extractResultText()
}
```

**Skill source priority:**
```
Local commands (getCommands) > MCP skills (loadedFrom === 'mcp')
// uniqBy gives local priority on name collision
```

### 3.7 Reference File System

The `files` field of bundled skills is extracted to disk on first invocation:

```typescript
// Extraction directory: getBundledSkillsRoot() + skillName
// Security:
// - Unpredictable path via per-process nonce
// - 0o700 directory, 0o600 file permissions
// - O_NOFOLLOW | O_EXCL flags (symlink attack prevention)
// - Path traversal validation (normalize + '..' check)

// Prepended to prompt after extraction:
"Base directory for this skill: /tmp/.claude-bundled-skills-{nonce}/{skillName}"
```

---

## 4. Hook System

### 4.1 Architecture Overview

Hooks are a mechanism for executing user-defined code at various points in the Claude Code lifecycle.

**Key files:**
- `src/utils/hooks.ts` (5,022 lines) - Hook execution engine
- `src/schemas/hooks.ts` - Hook schema definitions
- `src/entrypoints/sdk/coreSchemas.ts` - Hook event list

### 4.2 Hook Event List (27 events)

```typescript
const HOOK_EVENTS = [
  // === Tool lifecycle ===
  'PreToolUse',          // Before tool execution (Can approve/deny/modify)
  'PostToolUse',         // After tool execution (Result inspection)
  'PostToolUseFailure',  // On tool execution failure

  // === Session lifecycle ===
  'SessionStart',        // Session start
  'SessionEnd',          // Session end (Timeout: 1.5s default)
  'Setup',               // Initial setup stage

  // === User interaction ===
  'UserPromptSubmit',    // User prompt submission
  'Notification',        // Notification delivery
  'Stop',                // Model response stop
  'StopFailure',         // Stop failure

  // === Subagent ===
  'SubagentStart',       // Subagent start
  'SubagentStop',        // Subagent stop
  'TeammateIdle',        // Teammate idle state

  // === Task ===
  'TaskCreated',         // Task created
  'TaskCompleted',       // Task completed

  // === Context management ===
  'PreCompact',          // Before context compaction
  'PostCompact',         // After context compaction
  'InstructionsLoaded',  // Instructions loaded

  // === Permission ===
  'PermissionRequest',   // Permission request
  'PermissionDenied',    // Permission denied

  // === MCP Elicitation ===
  'Elicitation',         // Elicitation request
  'ElicitationResult',   // Elicitation result

  // === Settings/Environment ===
  'ConfigChange',        // Config change
  'CwdChanged',          // Working directory change
  'FileChanged',         // File change detection

  // === Worktree ===
  'WorktreeCreate',      // Worktree creation
  'WorktreeRemove',      // Worktree removal
] as const
```

### 4.3 Hook Types (4 types)

#### Command Hook (Shell command)
```typescript
{
  type: 'command',
  command: string,        // Shell command to execute
  if?: string,            // Conditional execution (permission rule syntax)
  shell?: 'bash' | 'powershell',  // Shell interpreter
  timeout?: number,       // Timeout in seconds
  statusMessage?: string, // Spinner message
  once?: boolean,         // Execute once then remove
  async?: boolean,        // Background execution (non-blocking)
  asyncRewake?: boolean   // Background + wake model on exit code 2
}
```

#### Prompt Hook (LLM prompt)
```typescript
{
  type: 'prompt',
  prompt: string,         // Prompt to pass to LLM ($ARGUMENTS placeholder)
  if?: string,
  timeout?: number,
  model?: string,         // Model override (e.g., "claude-sonnet-4-6")
  statusMessage?: string,
  once?: boolean
}
```

#### HTTP Hook (Webhook)
```typescript
{
  type: 'http',
  url: string,            // URL to POST to (valid URL required)
  if?: string,
  timeout?: number,
  headers?: Record<string, string>,   // $VAR_NAME environment variable interpolation supported
  allowedEnvVars?: string[],          // Whitelist of environment variables allowed for interpolation
  statusMessage?: string,
  once?: boolean
}
```

#### Agent Hook (Agentic verifier)
```typescript
{
  type: 'agent',
  prompt: string,         // Content to verify ($ARGUMENTS placeholder)
  if?: string,
  timeout?: number,       // Default 60 seconds
  model?: string,         // Default: Haiku
  statusMessage?: string,
  once?: boolean
}
```

### 4.4 Hook Matcher Structure

```typescript
// Hook configuration structure in settings.json:
{
  "hooks": {
    "PreToolUse": [           // Event name
      {
        "matcher": "Write",   // Matching pattern (tool name, etc.)
        "hooks": [            // Array of hooks to execute on match
          {
            "type": "command",
            "command": "echo 'File write detected'"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "npm run lint",
            "if": "Bash(npm *)"   // Conditional: only for npm commands
          }
        ]
      }
    ]
  }
}
```

### 4.5 Conditional Execution (`if` field)

Filtering via permission rule syntax:

```typescript
// Syntax: "ToolName(pattern)"
// Examples:
"Bash(git *)"         // Only for Bash commands starting with git
"Read(*.ts)"          // Only when reading .ts files
"Write"               // All Write tool calls
"Edit(src/**)"        // Only when editing files under src/

// Evaluation: Matches against tool_name and tool_input of hook_input
// Evaluated before spawn → No process creation on non-match
```

### 4.6 Async Execution Mode

```typescript
// async: true
// - Runs in background
// - Non-blocking
// - Registered in AsyncHookRegistry

// asyncRewake: true
// - Runs in background (implies async)
// - Wakes the model on exit code 2 (task-notification queue)
// - Use case: Result feedback after long-running verification
```

### 4.7 One-shot Hooks

```typescript
{
  once: true  // Automatically removed after 1 execution
}
// Use case: One-time initialization at session start
```

### 4.8 Hook Input

Default input passed to all hooks:

```typescript
type BaseHookInput = {
  session_id: string
  transcript_path: string
  cwd: string
  permission_mode?: string
  agent_id?: string        // Only present in subagent context
  agent_type?: string      // Agent type name
}
```

Additional fields per event:

| Event | Additional fields |
|--------|-----------|
| `PreToolUse` | `tool_name`, `tool_input` |
| `PostToolUse` | `tool_name`, `tool_input`, `tool_output` |
| `UserPromptSubmit` | `user_prompt` |
| `SessionStart` | (default only) |
| `SessionEnd` | `exit_reason` |
| `SubagentStart` | `agent_id`, `agent_type` |
| `SubagentStop` | `agent_id`, `agent_type` |
| `PermissionRequest` | `tool_name`, `tool_input` |
| `FileChanged` | `file_path`, `change_type` |
| `CwdChanged` | `old_cwd`, `new_cwd` |

### 4.9 Hook Output

Hook stdout parsed as JSON:

```typescript
type HookJSONOutput = {
  // Synchronous output (SyncHookJSONOutput)
  continue?: boolean            // false: Stop execution
  suppressOutput?: boolean      // Suppress output
  stopReason?: string           // Stop reason
  decision?: 'approve' | 'block'
  reason?: string
  systemMessage?: string        // System message injection
  permissionDecision?: 'allow' | 'deny' | 'ask'

  // Event-specific output
  hookSpecificOutput?: {
    hookEventName: 'PreToolUse' | 'PostToolUse' | 'UserPromptSubmit'
    // PreToolUse: permissionDecision, permissionDecisionReason, updatedInput
    // PostToolUse: additionalContext
    // UserPromptSubmit: additionalContext
  }

  // Asynchronous output (AsyncHookJSONOutput)
  processId?: string
  asyncRewake?: boolean
}
```

### 4.10 Hook Execution Result Structure

```typescript
type HookResult = {
  message?: HookResultMessage
  systemMessage?: string
  blockingError?: { blockingError: string; command: string }
  outcome: 'success' | 'blocking' | 'non_blocking_error' | 'cancelled'
  preventContinuation?: boolean
  stopReason?: string
  permissionBehavior?: 'ask' | 'deny' | 'allow' | 'passthrough'
  hookPermissionDecisionReason?: string
  additionalContext?: string
  initialUserMessage?: string
  updatedInput?: Record<string, unknown>   // Tool input modification
  updatedMCPToolOutput?: unknown           // MCP output modification
  permissionRequestResult?: PermissionRequestResult
  elicitationResponse?: ElicitResult  // Imported from @modelcontextprotocol/sdk/types.js
  // ElicitResult = { action: 'accept' | 'decline' | 'cancel', content?: Record<string, unknown> }
  watchPaths?: string[]
  retry?: boolean
  hook: HookCommand | HookCallback | FunctionHook
}
```

### 4.11 Security and Trust

```typescript
// All hooks require workspace trust
function shouldSkipHookDueToTrust(): boolean {
  // SDK (non-interactive): Always execute (trust implied)
  // Interactive: Check checkHasTrustDialogAccepted()
  // Skip hooks without trust
}

// Hook config snapshot: captureHooksConfigSnapshot()
// Captured before showing trust dialog → Ensures safe ordering

// Managed hooks only mode
function shouldAllowManagedHooksOnly(): boolean
function shouldDisableAllHooksIncludingManaged(): boolean
```

### 4.12 Timeout

```typescript
const TOOL_HOOK_EXECUTION_TIMEOUT_MS = 10 * 60 * 1000  // 10 minutes (tool hooks)
const SESSION_END_HOOK_TIMEOUT_MS_DEFAULT = 1500        // 1.5 seconds (session end)
// Overridable via CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS environment variable
```

---

## 5. LSP Integration

### 5.1 Architecture Overview

LSP (Language Server Protocol) integration provides code intelligence features. It is plugin-exclusive and cannot be configured via user/project settings.

**Key files:**
- `src/services/lsp/LSPServerManager.ts` - Server manager (factory function pattern)
- `src/services/lsp/LSPClient.ts` - JSON-RPC client
- `src/services/lsp/LSPServerInstance.ts` - Individual server instance
- `src/services/lsp/LSPDiagnosticRegistry.ts` - Diagnostic registry
- `src/services/lsp/config.ts` - Loading LSP servers from plugins
- `src/tools/LSPTool/LSPTool.ts` - LSP tool for LLM

### 5.2 LSPServerManager Singleton

```typescript
type LSPServerManager = {
  initialize(): Promise<void>            // Load all configured servers
  shutdown(): Promise<void>              // Shut down all servers
  getServerForFile(filePath): LSPServerInstance | undefined
  ensureServerStarted(filePath): Promise<LSPServerInstance | undefined>
  sendRequest<T>(filePath, method, params): Promise<T | undefined>
  getAllServers(): Map<string, LSPServerInstance>

  // File synchronization
  openFile(filePath, content): Promise<void>     // didOpen
  changeFile(filePath, content): Promise<void>   // didChange
  saveFile(filePath): Promise<void>              // didSave
  closeFile(filePath): Promise<void>             // didClose
  isFileOpen(filePath): boolean
}
```

**Closure-based state encapsulation:**
```typescript
function createLSPServerManager(): LSPServerManager {
  // Factory function + closure pattern, not a class
  const servers: Map<string, LSPServerInstance> = new Map()
  const extensionMap: Map<string, string[]> = new Map()
  const openedFiles: Map<string, string> = new Map()
  // ... method implementations
}
```

### 5.3 LSPClient (JSON-RPC)

```typescript
type LSPClient = {
  readonly capabilities: ServerCapabilities | undefined
  readonly isInitialized: boolean
  start(command, args, options?): Promise<void>
  initialize(params: InitializeParams): Promise<InitializeResult>
  sendRequest<T>(method, params): Promise<T>
  sendNotification(method, params): Promise<void>
  onNotification(method, handler): void
  onRequest<P, R>(method, handler): void
  stop(): Promise<void>
}
```

- Uses `createMessageConnection` from `vscode-jsonrpc/node.js`
- stdio communication via `StreamMessageReader`/`StreamMessageWriter`
- Crash detection and propagation via `onCrash` callback

### 5.4 Supported 9 LSP Operations

```typescript
type LSPOperation =
  | 'goToDefinition'          // textDocument/definition
  | 'findReferences'          // textDocument/references
  | 'hover'                   // textDocument/hover
  | 'documentSymbol'          // textDocument/documentSymbol
  | 'workspaceSymbol'         // workspace/symbol
  | 'goToImplementation'      // textDocument/implementation
  | 'prepareCallHierarchy'    // textDocument/prepareCallHierarchy
  | 'incomingCalls'           // callHierarchy/incomingCalls (2-step)
  | 'outgoingCalls'           // callHierarchy/outgoingCalls (2-step)
```

**2-step invocation (incomingCalls/outgoingCalls):**
```
Step 1: textDocument/prepareCallHierarchy → CallHierarchyItem[]
Step 2: callHierarchy/incomingCalls(item) → CallHierarchyIncomingCall[]
```

**Coordinate conversion:**
- User input: 1-based (same as editor display)
- LSP protocol: 0-based
- Automatic conversion inside the tool: `line - 1`, `character - 1`

### 5.5 Diagnostic Registry (LSPDiagnosticRegistry)

```typescript
type PendingLSPDiagnostic = {
  serverName: string
  files: DiagnosticFile[]
  timestamp: number
  attachmentSent: boolean
}

// Volume limits:
const MAX_DIAGNOSTICS_PER_FILE = 10
const MAX_TOTAL_DIAGNOSTICS = 30
const MAX_DELIVERED_FILES = 500  // LRU cache

// Deduplication: cross-turn deduplication
// Pattern: registration → wait → attachment delivery → injection into conversation
```

### 5.6 LSP Server Config Schema

```typescript
type LspServerConfig = {
  command: string                                  // Execution command
  args?: string[]                                  // Command arguments
  extensionToLanguage: Record<string, string>      // File extension → language ID
  transport?: 'stdio' | 'socket'                   // Default: 'stdio'
  env?: Record<string, string>                     // Environment variables
  initializationOptions?: unknown                  // Initialization options
  settings?: unknown                               // Workspace settings
  workspaceFolder?: string                         // Workspace folder
  startupTimeout?: number                          // Startup timeout (ms)
  shutdownTimeout?: number                         // Shutdown timeout (ms)
  restartOnCrash?: boolean                         // Restart on crash
  maxRestarts?: number                             // Maximum restart count
}
```

---

## 6. Bridge System

### 6.1 Architecture Overview

The Bridge System is a bidirectional communication protocol between IDEs (VS Code, JetBrains, etc.) and the CLI. It includes remote session management, JWT authentication, and multi-session support.

**Key files:**
- `src/bridge/bridgeMain.ts` (2,999 lines) - Main bridge loop
- `src/bridge/replBridge.ts` (2,406 lines) - REPL bridge transport
- `src/bridge/bridgeApi.ts` - API client
- `src/bridge/types.ts` - Type definitions

### 6.2 Bridge Loop (bridgeMain)

```typescript
async function runBridgeLoop(
  config: BridgeConfig,
  environmentId: string,
  environmentSecret: string,
  api: BridgeApiClient,
  spawner: SessionSpawner,
  logger: BridgeLogger,
  signal: AbortSignal,
  backoffConfig?: BackoffConfig,
  initialSessionId?: string,
  getAccessToken?: () => string | undefined | Promise<string | undefined>
): Promise<void>
```

**Core operating principle:**
```
IDE/Web → Environment registration → Polling loop → Receive work → Create session → Run CLI
                        ↑                                    ↓
                     Heartbeat                           Send result
                        ↑                                    ↓
                    Token refresh ←────────────────────── Session complete
```

**Backoff configuration:**
```typescript
const DEFAULT_BACKOFF: BackoffConfig = {
  connInitialMs: 2_000,
  connCapMs: 120_000,       // 2 minutes (maximum)
  connGiveUpMs: 600_000,    // 10 minutes (give up)
  generalInitialMs: 500,
  generalCapMs: 30_000,
  generalGiveUpMs: 600_000,
  shutdownGraceMs?: 30_000, // SIGTERM→SIGKILL grace period
  stopWorkBaseDelayMs?: 1_000
}
```

### 6.2.1 Wire Protocol and Message Guarantees

```typescript
// SDKMessage discriminated union (bridgeMessaging.ts, types.ts)
type SDKControlRequest = {
  type: 'control_request'
  request_id: string
  request: {
    subtype: 'initialize' | 'set_model' | 'interrupt'
           | 'set_permission_mode' | 'set_max_thinking_tokens'
    // ... additional fields per subtype
  }
}

type SDKControlResponse = {
  type: 'control_response'
  response: { subtype: 'success' | 'error', request_id: string, response?: Record<string, unknown> }
}
```

**Session ID generation**: `crypto.randomUUID()` — RFC 4122 UUID

**Message delivery guarantees:**
- **Ordering guarantee**: BoundedUUIDSet ring buffer for echo + redelivery deduplication
- **At-least-once delivery**: On SSE reconnection, server resends history based on `from_sequence_num` (v2)
- **Echo deduplication**: `recentPostedUUIDs.has(uuid)` (bridgeMessaging.ts:168-172)

**Reconnection protocol:**
```
Trigger: WS close (4090 epoch mismatch, 4091 initialization failed, 4092 SSE budget exceeded) or polling error

Reconnection attempts:
  ├── Environment recreation: max 3 attempts
  ├── Polling error backoff: initial 2s → max 60s (exponential backoff)
  └── Polling error give-up: 15 minute timeout

Flow:
  1. reconnectPromise prevents duplicate reconnections (only 1 concurrent)
  2. api.reconnectSession(environmentId, sessionId) — force-kills stale workers on server
  3. Same environmentId returned → in-place reconnection
     Different environmentId → TTL expired, environment recreation
  4. Spawn new child session via createSession()
  5. SSE sequence number picks up from previous transmission
```

### 6.3 REPL Bridge Transport (replBridge)

```typescript
type ReplBridgeHandle = {
  bridgeSessionId: string
  environmentId: string
  sessionIngressUrl: string
  writeMessages(messages: Message[]): void
  writeSdkMessages(messages: SDKMessage[]): void
  sendControlRequest(request: SDKControlRequest): void
  sendControlResponse(response: SDKControlResponse): void
  sendControlCancelRequest(requestId: string): void
  sendResult(): void
  teardown(): Promise<void>
}

type BridgeState = 'ready' | 'connected' | 'reconnecting' | 'failed'
```

**BridgeCoreParams (dependency injection):**
```typescript
type BridgeCoreParams = {
  dir: string                    // Working directory
  machineName: string
  branch: string
  gitRepoUrl: string | null
  title: string
  baseUrl: string
  sessionIngressUrl: string
  workerType: string             // Worker type identifier
  getAccessToken: () => string | undefined
  createSession: (opts) => Promise<string | null>   // Session creation injection
  archiveSession: (sessionId) => Promise<void>      // Session archival injection
  getCurrentTitle?: () => string
  toSDKMessages?: (messages: Message[]) => SDKMessage[]
}
```

### 6.4 Session Management

```typescript
// Active session tracking
const activeSessions = new Map<string, SessionHandle>()
const sessionStartTimes = new Map<string, number>()
const sessionWorkIds = new Map<string, string>()
const sessionCompatIds = new Map<string, string>()
const sessionIngressTokens = new Map<string, string>()  // Heartbeat authentication
const sessionTimers = new Map<string, ReturnType<typeof setTimeout>>()
const completedWorkIds = new Set<string>()
const sessionWorktrees = new Map<string, WorktreeInfo>()
const timedOutSessions = new Set<string>()
const titledSessions = new Set<string>()
```

**Multi-session spawning:**
```typescript
const SPAWN_SESSIONS_DEFAULT = 32
// GrowthBook gate: tengu_ccr_bridge_multi_session
// --spawn / --capacity / --create-session-in-dir mode support
```

### 6.5 JWT Authentication and Trusted Devices

```typescript
// Token refresh scheduler
const tokenRefreshScheduler = createTokenRefreshScheduler()

// Trusted device token
const trustedDeviceToken = getTrustedDeviceToken()

// Session ingress authentication
const sessionIngressTokens = new Map<string, string>()
// JWT tokens used for heartbeat authentication
```

### 6.6 WebSocket/HTTP Transport

```typescript
// HybridTransport: WebSocket + HTTP fallback
import { HybridTransport } from '../cli/transports/HybridTransport.js'

// V1/V2 REPL transport
function createV1ReplTransport(): ReplBridgeTransport
function createV2ReplTransport(): ReplBridgeTransport
```

**Sleep detection:**
```typescript
// System sleep/wake detection threshold
function pollSleepDetectionThresholdMs(backoff: BackoffConfig): number {
  return backoff.connCapMs * 2  // 2x connCapMs
}
```

### 6.7 Worktree Management

```typescript
// Agent worktree creation/removal
const sessionWorktrees = new Map<string, {
  worktreePath: string
  worktreeBranch?: string
  gitRoot?: string
  hookBased?: boolean
}>()

import { createAgentWorktree, removeAgentWorktree } from '../utils/worktree.js'
```

---

## 7. Extension System Synthesis

### 7.1 Synthesis Structure

All extension systems are synthesized with `AppState` as the central hub:

```
                        ┌─────────────┐
                        │  AppState   │
                        │             │
                        │ .mcp        │◄── MCP servers, tools, resources
                        │ .plugins    │◄── Active plugin list
                        │ .tools      │◄── Full tool registry
                        │ .hooks      │◄── Hook config snapshot
                        └─────┬───────┘
                              │
              ┌───────────────┼───────────────┐
              │               │               │
        ┌─────▼─────┐  ┌─────▼─────┐  ┌─────▼─────┐
        │  Plugin A  │  │  Plugin B  │  │  Bundled   │
        │            │  │            │  │  Skills    │
        │ hooks  ────┼──┤ mcpServers─┤  │            │
        │ skills ────┤  │ hooks  ────┤  │ verify     │
        │ commands   │  │ lspServers │  │ simplify   │
        └────────────┘  └────────────┘  │ remember   │
                                        └────────────┘
```

### 7.2 What Plugins Provide

Extensions a single plugin can simultaneously provide:

| Extension Type | Plugin Field | Registration Location |
|-----------|-------------|----------|
| MCP servers | `mcpServers` | `AppState.mcp.clients` |
| Tools | Via MCP servers | `AppState.mcp.tools` |
| Skills/commands | `commands`, `skills` | `getCommands()` registry |
| Agents | `agents` | Agent registry |
| Hooks | `hooks` (inline or `hooks/hooks.json`) | Hook config merge |
| LSP servers | `lspServers` | `LSPServerManager` |
| Output styles | `outputStyles` | Output formatter |
| Settings | `settings` | Settings cascade merge |
| Channels | `channels` | Assistant mode message routing |

### 7.3 Interaction Between Hooks and Tool Execution

```
User prompt → UserPromptSubmit hook
                      ↓
Model response → Tool call decision
                      ↓
              PreToolUse hook ─── Deny → Return denial result to model
                      ↓ Approve
              Tool execution (MCPTool, BashTool, etc.)
                      ↓
              PostToolUse hook ─── Inject additional context
                      ↓
              Return result to model
                      ↓
              Stop hook (on response completion)
```

### 7.4 How Skills Invoke Tools

```
SkillTool.call(input: { skill: "verify" })
      ↓
findCommand("verify") → BundledSkillDefinition
      ↓
executeForkedSkill() → Create isolated subagent
      ↓
Subagent calls tools according to allowedTools
      ↓
SubagentStart/Stop hooks fire
      ↓
Extract result → Return as SkillTool result
```

### 7.5 MCP Skill Integration

```typescript
// When MCP server provides skills:
const mcpSkills = context.getAppState().mcp.commands
  .filter(cmd => cmd.type === 'prompt' && cmd.loadedFrom === 'mcp')

// SkillTool also searches MCP skills:
async function getAllCommands(context): Promise<Command[]> {
  const localCommands = await getCommands(getProjectRoot())
  return uniqBy([...localCommands, ...mcpSkills], 'name')
  // Local takes priority, MCP skills are supplementary
}
```

### 7.6 Synthesis in Settings Cascade

```
Enterprise (managed) settings        ← Highest priority
      ↓
User settings (~/.claude/settings.json)
      ↓
Project settings (.claude/settings.json)
      ↓
Local settings (.claude/settings.local.json)
      ↓
Plugin settings (settings field in plugin.json)  ← Lowest priority
      ↓
hooks, mcpServers, enabledPlugins, etc. merged at each layer
```

### 7.7 Full Runtime Flow

```
CLI startup
  ├── initBundledSkills()        → Register bundled skills
  ├── initBuiltinPlugins()       → Register built-in plugins
  ├── loadAllPluginsCacheOnly()  → Load marketplace plugins
  │   ├── Manifest validation
  │   ├── Hook config merge
  │   ├── MCP server extraction
  │   └── Command/skill registration
  ├── getAllMcpConfigs()          → Collect MCP server configs
  │   ├── Manual config (local/user/project)
  │   ├── Plugin MCP servers (deduplicated)
  │   ├── claude.ai connector (deduplicated)
  │   └── Enterprise settings
  ├── connectToServers()         → Batch connect MCP servers
  │   ├── Local servers (batch 3)
  │   └── Remote servers (batch 20)
  ├── createLSPServerManager()   → Initialize LSP servers
  │   └── Load LSP config from plugins
  └── captureHooksConfigSnapshot() → Hook config snapshot
      └── Activate hooks after trust check
```

---

### 7.8 Plugin Dependency Resolution

```typescript
// Dependency declaration: manifest.dependencies?: string[]
// Example: ["my-dep", "other@marketplace-name"]
// Bare names inherit the declaring plugin's marketplace

// On install: DFS cycle detection
// dependencyResolver.ts:95-159
if (stack.includes(id)) {
  return { ok: false, reason: 'cycle', chain: [...stack, id] }
}

// On load: Fixed-point loop to auto-demote unsatisfied dependencies
// dependencyResolver.ts:177-233 — verifyAndDemote()
// Unsatisfied reasons: 'not-enabled' (exists but disabled) | 'not-found' (absent)
// Does not modify config files — session-local, shown to user via /doctor command
```

**Loading order:**
1. Parallel: Marketplace + session-only (--plugin-dir) plugins
2. Synchronous: Built-in plugins (getBuiltinPlugins())
3. Merge: Session > marketplace > built-in (session takes priority on same name)
4. Dependency verification: verifyAndDemote (not topological sort — only checks existence)
5. Filter + cache: Active plugins only

**Failure handling:** Non-fatal. Failed plugins are demoted to disabled, errors collected → displayed in `/doctor`. Other plugins continue to load.

---

## Implementation Caveats

### C1. MCP Tool Call Failure — No Retry
When MCP connection drops, in-flight `callTool()` Promises are immediately rejected (-32000). **There is no infrastructure-level retry** — retries depend on the model (LLM) decision.

### C2. MCP OAuth Token — Response-based Refresh Only
Token refresh is only triggered on server 401 **response**. Calls initiated with near-expired tokens execute without refresh and may result in 401 errors. Proactive refresh is not implemented.

### C3. MCP toolName Collision — Silent Overwrite
When two MCP servers register the same toolName, the later-registered server's tools **silently overwrite** the earlier one. Namespace prefixes (`mcp__serverName__toolName`) exist but do not prevent shortname collisions.

### C4. Hook Parallel Execution — No updatedInput Chaining
PreToolUse hooks are executed **in parallel** via `Promise.all()`. Each hook sees only the **original input** and cannot see other hooks' `updatedInput`. If two hooks modify the same key, only the last aggregated value is applied.

### C5. Hook Permission Decision Priority
When multiple hooks return conflicting decisions: **deny > ask > allow**. If any hook returns deny, it overrides allow from all other hooks.

### C6. Plugin Reload MCP Connections
When a plugin is reloaded/disabled, its MCP server connections are dropped. In-flight tool calls receive connection-lost errors. No automatic retry.

### C7. Skill Recursive Invocation
Skills can invoke other skills, and no explicit prevention mechanism for infinite recursion is documented. A depth limit should be added during implementation.

---

## Appendix: Key Constants and Limits

| Constant | Value | Description |
|------|------|------|
| `DEFAULT_MCP_TOOL_TIMEOUT_MS` | 100,000,000 (~27.8h) | MCP tool call timeout |
| `MAX_MCP_DESCRIPTION_LENGTH` | 2,048 | Maximum tool description length |
| `MCP_REQUEST_TIMEOUT_MS` | 60,000 (60s) | Individual MCP request timeout |
| `MCP_AUTH_CACHE_TTL_MS` | 900,000 (15min) | Auth cache TTL |
| `TOOL_HOOK_EXECUTION_TIMEOUT_MS` | 600,000 (10min) | Tool hooks timeout |
| `SESSION_END_HOOK_TIMEOUT_MS` | 1,500 (1.5s) | Session end hook timeout |
| `MAX_LSP_FILE_SIZE_BYTES` | 10,000,000 (10MB) | LSP analysis file size limit |
| `MAX_DIAGNOSTICS_PER_FILE` | 10 | Per-file LSP diagnostic limit |
| `MAX_TOTAL_DIAGNOSTICS` | 30 | Total LSP diagnostic limit |
| `MAX_DELIVERED_FILES` | 500 | Delivered file tracking (LRU) |
| `SPAWN_SESSIONS_DEFAULT` | 32 | Bridge multi-session default |
| `MCP Connection Batch (local)` | 3 | Local MCP server batch size |
| `MCP Connection Batch (remote)` | 20 | Remote MCP server batch size |
