# Part 1: Architecture Overview

> Reverse engineering design document for the Claude Code CLI
> Precision analysis based on source code (src/ directory, 1,902 files, approximately 512,664 LOC)

---

## 1. System Overview

### 1.1 What is Claude Code?

Claude Code is a **terminal-based AI coding assistant CLI** developed by Anthropic. Through an interactive REPL (Read-Eval-Print Loop), users and the Claude AI model interact in real-time to perform file editing, code searching, command execution, MCP server integration, and more.

Key features:
- **Interactive REPL**: React + Ink-based terminal UI (fullscreen layout)
- **Non-interactive mode**: Pipeline/SDK integration support via the `--print` flag
- **Tool system**: 30+ built-in tools (Bash, Edit, Read, Grep, etc.) + MCP extensions
- **Permission system**: 3-tier allow/deny/ask permissions per tool + auto-mode classifier
- **Multi-agent**: Subagent spawning, team swarms, coordinator mode
- **Plugin architecture**: External plugins, skills, bundled skills
- **Session management**: Conversation persistence, resume, fork, teleport

### 1.2 Technology Stack

| Category | Technology | Purpose |
|----------|-----------|---------|
| **Runtime** | Bun | Bundler + runtime (Node.js compatible, `bun:bundle` `feature()` DCE support) |
| **Language** | TypeScript (ESM) | Entire codebase, `.js` extension import convention |
| **UI Framework** | React 19 + Ink 5 | Terminal TUI rendering (React Compiler applied) |
| **CLI Parsing** | Commander.js (`@commander-js/extra-typings`) | CLI arguments/options/subcommands |
| **Schema Validation** | Zod v4 (`zod/v4`) | Tool input schemas, configuration validation |
| **Search Engine** | ripgrep (rg) | File search backend for Grep/Glob tools |
| **AI SDK** | `@anthropic-ai/sdk` | Claude API streaming calls |
| **MCP** | `@modelcontextprotocol/sdk` | MCP server client, tools/resources/prompts |
| **Telemetry** | OpenTelemetry | Metrics, tracing, logging (gRPC export) |
| **Feature Flags** | GrowthBook | A/B testing, feature gating |
| **State Management** | Custom Store pattern | getState/setState/subscribe (React-agnostic) |

### 1.3 Build Variants

Two build targets exist:

| Variant | `USER_TYPE` | Description |
|---------|-------------|-------------|
| **ant** (internal) | `'ant'` | Anthropic internal only. Includes REPL Tool, Config Tool, Tungsten Tool, etc. |
| **external** (public) | `'external'` | Public distribution. Internal-only tools/commands removed via DCE |

Tools/commands are conditionally included or excluded via `require()` based on the `process.env.USER_TYPE` value.

---

## 2. Directory Structure

```
src/                          # 1,902 files (1,884 TS/TSX)
├── main.tsx                  # Entry point: main() function, Commander.js setup, full startup sequence
├── Tool.ts                   # Tool type system definitions (Tool, ToolDef, buildTool, ToolUseContext)
├── tools.ts                  # Tool registry (getAllBaseTools, getTools, assembleToolPool)
├── commands.ts               # Command registry (getCommands, slash commands, skills)
├── QueryEngine.ts            # QueryEngine class: conversation session management, submitMessage loop
├── query.ts                  # query() function: API call + tool execution + streaming loop
├── context.ts                # Context collection (getSystemContext, getUserContext, gitStatus)
├── replLauncher.tsx          # React/Ink REPL launch (App + REPL component mount)
├── cost-tracker.ts           # API cost tracking
├── history.ts                # Conversation history management
│
├── assistant/        (1)     # Kairos assistant mode
├── bootstrap/        (1)     # Global state seed (state.ts: session ID, CWD, model, SDK betas, etc.)
├── bridge/          (31)     # Remote control bridge (mobile/web integration)
├── buddy/            (6)     # Companion character UI (BUDDY feature)
├── cli/             (19)     # CLI utilities, subcommand handlers
├── commands/       (207)     # Slash command implementations (80+ commands)
│   ├── add-dir/              #   /add-dir: additional working directories
│   ├── clear/                #   /clear: screen reset
│   ├── compact/              #   /compact: context compaction
│   ├── config/               #   /config: settings management
│   ├── mcp/                  #   /mcp: MCP server management (add, remove, list, serve)
│   ├── resume/               #   /resume: session resume
│   ├── review.ts             #   /review: code review
│   ├── commit.ts             #   /commit: Git commit (internal only)
│   └── ...                   #   70+ additional commands
├── components/     (389)     # React/Ink UI components
│   ├── App.tsx               #   Top-level app wrapper (Context Providers)
│   ├── TextInput.tsx          #   Prompt input component
│   ├── MessageList.tsx        #   Message list rendering
│   ├── Spinner.tsx            #   Spinner/progress indicator
│   ├── PermissionDialog.tsx   #   Permission confirmation dialog
│   └── ...                   #   380+ UI components
├── constants/       (21)     # Constant definitions (querySource, xml tags, common constants)
├── context/          (9)     # React Context definitions (notifications, mailbox, stats, voice)
├── coordinator/      (1)     # Coordinator mode (multi-agent orchestration)
├── entrypoints/      (8)     # Entry point variants (cli.tsx, agentSdk, init.ts)
├── hooks/          (104)     # React Hooks (useCanUseTool, useMergedTools, useSettingsChange, etc.)
├── ink/             (96)     # Ink extensions (terminal I/O, rendering engine, key events)
├── keybindings/     (14)     # Keyboard binding system
├── memdir/           (8)     # Memory directory (MEMORY.md, auto-memory)
├── migrations/      (11)     # Migrations (settings/model string upgrades)
├── moreright/        (1)     # Additional permission system utilities
├── native-ts/        (4)     # Native TS utilities (clipboard, tree-sitter)
├── outputStyles/     (1)     # Output style definitions
├── plugins/          (2)     # Plugin system (bundled, builtinPlugins)
├── query/            (4)     # Query-related modules (stopHooks, speculative execution)
├── remote/           (4)     # Remote session management (RemoteSessionManager)
├── schemas/          (1)     # JSON schema definitions
├── screens/          (3)     # Main screens (REPL.tsx: ~5,000 lines, ResumeConversation)
├── server/           (3)     # Server mode (direct connect, SDK server)
├── services/       (130)     # Service layer
│   ├── analytics/            #   Analytics (GrowthBook, Statsig, event logging)
│   ├── api/                  #   API client (claude.ts, streaming, retry)
│   ├── compact/              #   Context compaction (auto-compact, reactive, snip)
│   ├── mcp/                  #   MCP client (connection, configuration, tool conversion)
│   ├── lsp/                  #   LSP server management
│   ├── policyLimits/         #   Policy limits (enterprise)
│   ├── remoteManagedSettings/ #   Remote managed settings (enterprise)
│   ├── tips/                 #   Tips system
│   └── ...                   #   OAuth, plugin search, prompt suggestions, etc.
├── skills/          (20)     # Skill system (loading, bundled skills, dynamic discovery)
├── state/            (6)     # State management (Store, AppState, AppStateStore, onChangeAppState)
├── tasks/           (12)     # Task system (types, state, CRUD)
├── tools/          (184)     # Tool implementations
│   ├── AgentTool/            #   Subagent creation/management
│   ├── BashTool/             #   Bash command execution
│   ├── FileEditTool/         #   File editing (string replacement)
│   ├── FileReadTool/         #   File reading
│   ├── FileWriteTool/        #   File writing
│   ├── GlobTool/             #   File pattern search
│   ├── GrepTool/             #   Content search (ripgrep)
│   ├── SkillTool/            #   Skill invocation
│   ├── WebSearchTool/        #   Web search
│   ├── TodoWriteTool/        #   Todo list management
│   ├── ToolSearchTool/       #   Deferred tool search
│   ├── TaskCreateTool/       #   Task creation
│   ├── TaskUpdateTool/       #   Task update
│   ├── SendMessageTool/      #   Inter-teammate messaging
│   ├── TeamCreateTool/       #   Team creation
│   └── ...                   #   30+ additional tools
├── types/           (11)     # Shared type definitions (message, permissions, hooks, ids, utils)
├── upstreamproxy/    (2)     # Upstream proxy (mTLS, corporate proxy)
├── utils/          (564)     # Utilities (largest directory)
│   ├── permissions/          #   Permission system (PermissionMode, denialTracking, autoMode)
│   ├── settings/             #   Settings management (settings.json, MDM, validation)
│   ├── model/                #   Model management (model.ts, deprecation, capabilities)
│   ├── hooks/                #   Hook execution engine (executeHooks, hookHelpers)
│   ├── plugins/              #   Plugin loading/management
│   ├── sandbox/              #   Sandbox management (macOS seatbelt)
│   ├── shell/                #   Shell utilities (PowerShell, bash parsing)
│   ├── swarm/                #   Team swarm utilities
│   ├── teleport/             #   Session teleport
│   ├── git.ts                #   Git integration
│   ├── ripgrep.ts            #   ripgrep bindings
│   ├── fileStateCache.ts     #   File state cache
│   ├── sessionStorage.ts     #   Session persistence
│   └── ...                   #   500+ utility files
├── vim/              (5)     # Vim mode support
└── voice/            (1)     # Voice mode
```

---

## 3. Startup Sequence

### 3.1 Overall Flow

The `main()` function in `src/main.tsx` is the entry point. Startup proceeds in 5 phases:

```
[Phase 0] Parallel prefetch during module evaluation (at import time)
[Phase 1] main() entry → basic initialization
[Phase 2] Commander.js preAction → init() → migrations
[Phase 3] action() handler → setup() → settings/auth/permissions
[Phase 4] REPL rendering + deferred prefetch
```

### 3.2 Phase 0: Parallel Prefetch During Module Evaluation

At the top of the `main.tsx` file, 3 async operations are immediately started as import side effects. These run in parallel with the remaining ~135ms of import evaluation.

```typescript
// Top of main.tsx (executed at import time)

// 1. Record profiling checkpoint
profileCheckpoint('main_tsx_entry');

// 2. Start MDM (Mobile Device Management) raw data read
//    - macOS: spawn plutil subprocess
//    - Windows: spawn reg query subprocess
startMdmRawRead();

// 3. Start macOS Keychain prefetch
//    - Read OAuth token + legacy API key in parallel
//    - Saves ~65ms compared to synchronous spawn
startKeychainPrefetch();

// ... remaining ~135ms of module imports proceed
profileCheckpoint('main_tsx_imports_loaded');
```

### 3.3 Phase 1: main() Function Entry

```
main()
├── Security: set NoDefaultCurrentDirectoryInExePath (Windows)
├── Warning handler initialization
├── SIGINT/exit signal handler registration
├── Special URL schema handling (cc://, claude assistant, claude ssh)
├── Early detection of -p/--print flag → determine isNonInteractive
├── setIsInteractive() / initializeEntrypoint() setup
├── Client type determination (cli, sdk-cli, github-action, remote, etc.)
├── eagerLoadSettings(): early parsing of --settings, --setting-sources flags
└── run() invocation
```

### 3.4 Phase 2: Commander.js + preAction Hook

```
run()
├── Create Commander program + define options (50+ options)
├── Register preAction Hook:
│   ├── ensureMdmSettingsLoaded()     // Wait for Phase 0 MDM subprocess completion
│   ├── ensureKeychainPrefetchCompleted() // Wait for Phase 0 Keychain completion
│   ├── init()                        // Core initialization
│   │   ├── enableConfigs()           // Enable settings system
│   │   ├── applySafeConfigEnvironmentVariables()  // Apply safe environment variables
│   │   ├── applyExtraCACertsFromConfig()  // TLS certificate setup
│   │   ├── setupGracefulShutdown()   // Shutdown handlers
│   │   ├── API preconnect (preconnectAnthropicApi)
│   │   ├── GrowthBook initialization (initializeGrowthBook)
│   │   ├── Remote managed settings loading initialization
│   │   └── Telemetry initialization (OpenTelemetry)
│   ├── initSinks()                   // Connect analytics event sinks
│   ├── runMigrations()               // Up to 11 synchronous + 1 asynchronous
│   │   ├── migrateAutoUpdatesToSettings
│   │   ├── migrateBypassPermissionsAcceptedToSettings
│   │   ├── migrateEnableAllProjectMcpServersToSettings
│   │   ├── resetProToOpusDefault
│   │   ├── migrateSonnet1mToSonnet45
│   │   ├── migrateLegacyOpusToCurrent
│   │   ├── migrateSonnet45ToSonnet46
│   │   ├── migrateOpusToOpus1m
│   │   ├── migrateReplBridgeEnabledToRemoteControlAtStartup
│   │   ├── resetAutoModeOptInForDefaultOffer (conditional on TRANSCRIPT_CLASSIFIER)
│   │   ├── migrateFennecToOpus (ant build only, DCE'd in public build)
│   │   └── migrateChangelogFromConfig() [async fire-and-forget, always runs]
│   ├── loadRemoteManagedSettings()   // Enterprise remote settings (non-blocking)
│   └── loadPolicyLimits()            // Policy limits loading (non-blocking)
└── action() handler execution (Phase 3 below)
```

### 3.5 Phase 3: action() Handler (setup)

```
action(prompt, options)
├── Option parsing and validation
│   ├── Extract debug, verbose, model, agent, permissionMode, etc.
│   ├── MCP config parsing (--mcp-config)
│   ├── Agent definition loading (--agents)
│   ├── Session ID validation (--session-id)
│   └── Kairos/assistant mode gating
├── Non-interactive path branch (-p/--print → runHeadless)
│   └── Create QueryEngine → submitMessage() loop
├── Interactive path (REPL):
│   ├── showSetupScreens()
│   │   ├── Trust dialog (on first run)
│   │   ├── Auto-mode opt-in offer
│   │   ├── Kairos channel setup
│   │   └── Lodestone deep link resolution
│   ├── applyConfigEnvironmentVariables()  // Apply full environment variables
│   ├── initializeTelemetryAfterTrust()
│   ├── Tool permission context initialization (initializeToolPermissionContext)
│   ├── MCP server connection (getMcpToolsCommandsAndResources)
│   ├── Command loading (getCommands)
│   ├── Agent definition merge (getAgentDefinitionsWithOverrides)
│   ├── Initial AppState construction
│   ├── Store creation (createStore)
│   ├── Ink Root creation (getRenderContext)
│   └── launchRepl()
│       ├── Mount App component (Context Providers)
│       └── Mount REPL component (conversation loop)
└── startDeferredPrefetches() invocation (Phase 4)
```

### 3.6 Phase 4: Deferred Prefetch

Background tasks that run non-blocking after REPL rendering:

```
startDeferredPrefetches()
// No parameters — internally calls isBareMode() to determine

// Skip execution in bare mode (--print, --output-format, etc.)
if (isBareMode()) return

// Prefetch task list:
├── initUser()                                        // User info prefetch
├── getUserContext()                                   // CLAUDE.md file collection
├── prefetchSystemContextIfSafe()                      // git status (after trust confirmation)
├── getRelevantTips()                                  // Tips system
├── prefetchAwsCredentialsAndBedRockInfoIfSafe()       // AWS+Bedrock credentials (conditional)
├── prefetchGcpCredentialsIfSafe()                     // GCP credentials (conditional)
├── countFilesRoundedRg()                              // File count via ripgrep
├── initializeAnalyticsGates()                         // Analytics gates
├── prefetchOfficialMcpUrls()                          // MCP official registry
├── refreshModelCapabilities()                         // Model capability refresh
├── settingsChangeDetector.initialize()                // Settings change detector
├── skillChangeDetector.initialize()                   // Skill change detector
├── prefetchFastModeStatus()                           // Fast mode status prefetch
└── startEventLoopStallDetector()                      // Event loop stall detection (ant only)
```

### 3.7 Pseudocode: Full Startup Sequence

```typescript
// === Phase 0: Module top-level side effects ===
profileCheckpoint('main_tsx_entry')
startMdmRawRead()        // Async subprocess
startKeychainPrefetch()  // Async keychain read
// ... ~135ms import evaluation ...
profileCheckpoint('main_tsx_imports_loaded')

// === Phase 1: main() ===
async function main() {
  initializeWarningHandler()
  registerSignalHandlers()  // SIGINT, exit

  // Special CLI handling (cc://, ssh, assistant)
  rewriteArgvForSpecialModes()

  // Non-interactive mode detection
  const isNonInteractive = detectNonInteractive()
  setIsInteractive(!isNonInteractive)
  initializeEntrypoint(isNonInteractive)
  setClientType(determineClientType())

  // Early settings flag load
  eagerLoadSettings()

  await run()
}

// === Phase 2: Commander.js ===
async function run() {
  const program = new Commander()

  program.hook('preAction', async () => {
    // Wait for Phase 0 task completion
    await Promise.all([
      ensureMdmSettingsLoaded(),
      ensureKeychainPrefetchCompleted()
    ])

    await init()  // Core initialization (configs, env, shutdown, telemetry)
    initSinks()   // Analytics event sinks
    runMigrations()
    // runMigrations() internals:
    //   ├── migrateAutoUpdatesToSettings()
    //   ├── migrateBypassPermissionsAcceptedToSettings()
    //   ├── migrateEnableAllProjectMcpServersToSettings()
    //   ├── resetProToOpusDefault()
    //   ├── migrateSonnet1mToSonnet45()
    //   ├── migrateLegacyOpusToCurrent()
    //   ├── migrateSonnet45ToSonnet46()
    //   ├── migrateOpusToOpus1m()
    //   ├── migrateReplBridgeEnabledToRemoteControlAtStartup()
    //   ├── resetAutoModeOptInForDefaultOffer() [when TRANSCRIPT_CLASSIFIER flag is set]
    //   ├── migrateFennecToOpus()               [ant build only, DCE'd in public build]
    //   └── migrateChangelogFromConfig().catch(() => {})  // Async fire-and-forget

    // Non-blocking remote settings loading
    void loadRemoteManagedSettings()
    void loadPolicyLimits()
  })

  program
    .name('claude')
    .option('-p, --print', '...')
    .option('--model <model>', '...')
    // ... 50+ options ...
    .action(async (prompt, options) => {
      // === Phase 3: Setup + REPL launch ===
      if (isNonInteractive) {
        // Non-interactive: use QueryEngine directly
        const engine = new QueryEngine(config)
        for await (const msg of engine.submitMessage(prompt)) {
          emitToStdout(msg)
        }
        return
      }

      // Interactive: setup screens → REPL
      await showSetupScreens()       // Trust dialog, etc.
      await applyFullEnvVars()
      await initToolPermissions()
      const mcpResult = await connectMcpServers()
      const commands = await getCommands(cwd)
      const agents = await loadAgentDefinitions()

      const initialState = buildInitialAppState(...)
      const store = createStore(initialState, onChangeAppState)
      const root = getRenderContext()

      await launchRepl(root, { initialState, ... }, replProps, renderAndRun)

      // === Phase 4: Deferred prefetch ===
      startDeferredPrefetches()
    })

  await program.parseAsync(process.argv)
}
```

---

## 4. Data Flow Diagrams

### 4.1 Interactive Mode (REPL)

```
User Input (TextInput component)
       │
       ▼
┌─────────────────────────────────────────────────┐
│  REPL.tsx (screens/REPL.tsx ~5000 lines)        │
│  ┌─────────────────────────────────────┐        │
│  │ handleSubmit()                      │        │
│  │  ├─ processUserInput()              │        │
│  │  │   ├─ Slash command detection     │        │
│  │  │   │   └─ findCommand() → execute │        │
│  │  │   └─ Normal prompt → UserMessage │        │
│  │  ├─ getSystemPrompt()               │        │
│  │  ├─ getUserContext() (CLAUDE.md)     │        │
│  │  ├─ getSystemContext() (git status)  │        │
│  │  └─ query() invocation              │        │
│  └─────────────────────────────────────┘        │
└────────────────────┬────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────┐
│  query.ts → query() function                    │
│  (API call + tool execution main loop)          │
│                                                 │
│  while (shouldContinue) {                       │
│    ┌─ normalizeMessagesForAPI()                  │
│    ├─ prependUserContext() (CLAUDE.md injection) │
│    ├─ appendSystemContext() (git status inject.) │
│    │                                            │
│    ├─ API streaming call ─────────────────┐      │
│    │  (services/api/claude.ts)           │      │
│    │  Anthropic SDK messages.create()     │      │
│    │  stream=true, tools=[...]           │      │
│    │                                     │      │
│    │           ◄─── Streaming response ───┘      │
│    │                                            │
│    ├─ Text block → UI rendering                  │
│    ├─ Tool use block → tool execution pipeline   │
│    │   ├─ validateInput()                       │
│    │   ├─ checkPermissions()                    │
│    │   │   ├─ Permission rule matching           │
│    │   │   ├─ Auto-mode classifier (optional)    │
│    │   │   └─ User confirm dialog (if needed)    │
│    │   ├─ tool.call() ← tool execution           │
│    │   └─ Result → add ToolResult message        │
│    │                                            │
│    ├─ stop_reason check                          │
│    │   ├─ "end_turn" → exit loop                 │
│    │   ├─ "tool_use" → continue (send results)   │
│    │   └─ "max_tokens" → auto-continue           │
│    │                                            │
│    └─ Auto-compaction check (on token threshold) │
│        └─ autoCompact / snipCompact              │
│  }                                              │
└────────────────────┬────────────────────────────┘
                     │
                     ▼
         Message state update → UI re-render
```

### 4.2 Non-interactive Mode (--print / SDK)

```
SDK or CLI -p mode
       │
       ▼
┌──────────────────────────────┐
│  QueryEngine.submitMessage() │
│  (AsyncGenerator<SDKMessage>)│
│  ┌────────────────────────┐  │
│  │ processUserInputContext │  │
│  │ → fetchSystemPromptParts│  │
│  │ → query() invocation    │  │
│  │ → yield SDKMessage      │  │
│  │ → session save          │  │
│  └────────────────────────┘  │
└──────────────────────────────┘
       │
       ▼
  stdout (text/json/stream-json)
```

---

## 5. Module Dependency Rules

### 5.1 ESM + .js Extension

The entire codebase uses ESM (ECMAScript Modules). Import paths must include the `.js` extension:

```typescript
// Correct import
import { Tool } from './Tool.js'
import { getCommands } from './commands.js'
import { feature } from 'bun:bundle'

// Incorrect import (missing extension)
import { Tool } from './Tool'  // ❌
```

### 5.2 Circular Dependency Resolution: Lazy Require

Where circular dependencies arise, the lazy require pattern is used:

```typescript
// tools.ts - TeamCreateTool imports tools.ts back, so use lazy loading
const getTeamCreateTool = () =>
  require('./tools/TeamCreateTool/TeamCreateTool.js')
    .TeamCreateTool as typeof import('./tools/TeamCreateTool/TeamCreateTool.js').TeamCreateTool

// main.tsx - teammate.ts → AppState.tsx → ... → main.tsx cycle
const getTeammateUtils = () =>
  require('./utils/teammate.js') as typeof import('./utils/teammate.js')

// QueryEngine.ts - MessageSelector imports React/Ink, so lazy load
const messageSelector = (): typeof import('src/components/MessageSelector.js') =>
  require('src/components/MessageSelector.js')
```

This pattern maintains type safety through `typeof import(...)` casting.

### 5.3 DCE (Dead Code Elimination): feature() Function

The Bun bundler's `feature()` function (from the `bun:bundle` module) is used to eliminate unnecessary code at build time:

```typescript
import { feature } from 'bun:bundle'

// When feature('FLAG_NAME') is false, the bundler removes the entire block
const REPLTool = process.env.USER_TYPE === 'ant'
  ? require('./tools/REPLTool/REPLTool.js').REPLTool
  : null

const SleepTool = feature('PROACTIVE') || feature('KAIROS')
  ? require('./tools/SleepTool/SleepTool.js').SleepTool
  : null

const coordinatorModeModule = feature('COORDINATOR_MODE')
  ? require('./coordinator/coordinatorMode.js')
  : null
```

**Key rule**: `require()` must be used only inside `feature()` conditional blocks for DCE to work. Regular import statements are always included.

### 5.4 Analytics Module Zero-Import Rule

Analytics modules are never directly imported at the top level. To prevent circular dependencies and initialization order issues, they are either lazy-loaded or only `logEvent` is directly imported:

```typescript
// Only direct import of logEvent from services/analytics/index.js is permitted
import { logEvent } from 'src/services/analytics/index.js'

// GrowthBook, etc. are dynamically imported after init()
void import('../services/analytics/growthbook.js').then(gb => { ... })
```

---

## 6. Build System

### 6.1 Bun Bundler

Bun's built-in bundler is used as the build tool. Key characteristics:

- **Single binary output**: Self-contained executable via `bun build --compile`
- **DCE**: Build-time code removal based on `feature()` function
- **React Compiler**: `react/compiler-runtime` automatic memoization (JSX bytecode)
- **Tree Shaking**: Removal of unused exports based on ESM

### 6.2 Feature Flag List (89 flags)

Complete list of feature flags controlled by the Bun bundler's `feature()` function:

| Flag | Category | Description |
|------|----------|-------------|
| `ABLATION_BASELINE` | Experiment | Ablation baseline testing |
| `AGENT_MEMORY_SNAPSHOT` | Agent | Agent memory snapshots |
| `AGENT_TRIGGERS` | Agent | Scheduled task (cron) tools |
| `AGENT_TRIGGERS_REMOTE` | Agent | Remote triggers |
| `ALLOW_TEST_VERSIONS` | Development | Allow test versions |
| `ANTI_DISTILLATION_CC` | Security | Anti-distillation |
| `AUTO_THEME` | UI | Automatic theme detection |
| `AWAY_SUMMARY` | UI | Away summary |
| `BASH_CLASSIFIER` | Security | Bash command classifier |
| `BG_SESSIONS` | Session | Background sessions |
| `BREAK_CACHE_COMMAND` | Debug | Cache break command |
| `BRIDGE_MODE` | Remote | Bridge/remote control mode |
| `BUDDY` | UI | Companion character |
| `BUILDING_CLAUDE_APPS` | Skill | Claude app building skill |
| `BUILTIN_EXPLORE_PLAN_AGENTS` | Agent | Built-in explore/plan agents |
| `BYOC_ENVIRONMENT_RUNNER` | Infrastructure | BYOC environment runner |
| `CACHED_MICROCOMPACT` | Performance | Cached micro-compaction |
| `CCR_AUTO_CONNECT` | Remote | Auto remote connection |
| `CCR_MIRROR` | Remote | Remote mirroring |
| `CCR_REMOTE_SETUP` | Remote | Remote setup |
| `CHICAGO_MCP` | MCP | Chicago MCP server |
| `COMMIT_ATTRIBUTION` | Git | Commit attribution |
| `COMPACTION_REMINDERS` | Context | Compaction reminders |
| `CONNECTOR_TEXT` | UI | Connector text |
| `CONTEXT_COLLAPSE` | Context | Context collapse |
| `COORDINATOR_MODE` | Agent | Coordinator mode |
| `COWORKER_TYPE_TELEMETRY` | Telemetry | Coworker type telemetry |
| `DAEMON` | Infrastructure | Daemon mode |
| `DIRECT_CONNECT` | Remote | Direct connect (cc:// protocol) |
| `DOWNLOAD_USER_SETTINGS` | Settings | User settings download |
| `DUMP_SYSTEM_PROMPT` | Debug | System prompt dump |
| `ENHANCED_TELEMETRY_BETA` | Telemetry | Enhanced telemetry |
| `EXPERIMENTAL_SKILL_SEARCH` | Skill | Experimental skill search |
| `EXTRACT_MEMORIES` | Memory | Memory extraction |
| `FILE_PERSISTENCE` | Session | File persistence |
| `FORK_SUBAGENT` | Agent | Subagent fork |
| `HARD_FAIL` | Debug | Hard fail mode |
| `HISTORY_PICKER` | UI | History picker |
| `HISTORY_SNIP` | Context | History snip (partial trimming) |
| `HOOK_PROMPTS` | Hook | Hook prompts |
| `IS_LIBC_GLIBC` | Platform | glibc detection |
| `IS_LIBC_MUSL` | Platform | musl detection |
| `KAIROS` | Assistant | Kairos assistant mode (full) |
| `KAIROS_BRIEF` | Assistant | Kairos brief mode |
| `KAIROS_CHANNELS` | Assistant | Kairos channels |
| `KAIROS_DREAM` | Assistant | Kairos dream |
| `KAIROS_GITHUB_WEBHOOKS` | Assistant | Kairos GitHub webhooks |
| `KAIROS_PUSH_NOTIFICATION` | Assistant | Kairos push notifications |
| `LODESTONE` | Deep link | Deep link protocol handler |
| `MCP_RICH_OUTPUT` | MCP | MCP rich output |
| `MCP_SKILLS` | MCP | MCP skills |
| `MEMORY_SHAPE_TELEMETRY` | Telemetry | Memory shape telemetry |
| `MESSAGE_ACTIONS` | UI | Message actions |
| `MONITOR_TOOL` | Tool | Monitor tool |
| `NATIVE_CLIENT_ATTESTATION` | Security | Native client attestation |
| `NATIVE_CLIPBOARD_IMAGE` | Platform | Native clipboard image |
| `NEW_INIT` | Setup | New initialization |
| `OVERFLOW_TEST_TOOL` | Test | Overflow test tool |
| `PERFETTO_TRACING` | Performance | Perfetto tracing |
| `POWERSHELL_AUTO_MODE` | Shell | PowerShell auto mode |
| `PROACTIVE` | Agent | Proactive mode |
| `PROMPT_CACHE_BREAK_DETECTION` | Performance | Prompt cache break detection |
| `QUICK_SEARCH` | Search | Quick search |
| `REACTIVE_COMPACT` | Context | Reactive compaction |
| `REVIEW_ARTIFACT` | Skill | Review artifact |
| `RUN_SKILL_GENERATOR` | Skill | Skill generator |
| `SELF_HOSTED_RUNNER` | Infrastructure | Self-hosted runner |
| `SHOT_STATS` | Analytics | Shot statistics |
| `SKILL_IMPROVEMENT` | Skill | Skill improvement |
| `SLOW_OPERATION_LOGGING` | Performance | Slow operation logging |
| `SSH_REMOTE` | Remote | SSH remote mode |
| `STREAMLINED_OUTPUT` | UI | Streamlined output |
| `TEAMMEM` | Agent | Team memory |
| `TEMPLATES` | Workflow | Templates |
| `TERMINAL_PANEL` | UI | Terminal panel |
| `TOKEN_BUDGET` | Cost | Token budget |
| `TORCH` | Experiment | Torch |
| `TRANSCRIPT_CLASSIFIER` | Security | Transcript classifier (auto mode) |
| `TREE_SITTER_BASH` | Parsing | Tree-sitter Bash parser |
| `TREE_SITTER_BASH_SHADOW` | Parsing | Tree-sitter Bash shadow |
| `UDS_INBOX` | Communication | Unix domain socket inbox |
| `ULTRAPLAN` | Planning | UltraPlan mode |
| `ULTRATHINK` | Thinking | Ultra Think |
| `UNATTENDED_RETRY` | Agent | Unattended retry |
| `UPLOAD_USER_SETTINGS` | Settings | User settings upload |
| `VERIFICATION_AGENT` | Agent | Verification agent |
| `VOICE_MODE` | UI | Voice mode |
| `WEB_BROWSER_TOOL` | Tool | Web browser tool |
| `WORKFLOW_SCRIPTS` | Workflow | Workflow scripts |

### 6.3 USER_TYPE-Based Conditional Code

Build variants based on `process.env.USER_TYPE`:

```typescript
// ant-only tools
...(process.env.USER_TYPE === 'ant' ? [ConfigTool] : [])
...(process.env.USER_TYPE === 'ant' ? [TungstenTool] : [])
...(process.env.USER_TYPE === 'ant' && REPLTool ? [REPLTool] : [])

// ant-only commands
...(process.env.USER_TYPE === 'ant' && !process.env.IS_DEMO
  ? INTERNAL_ONLY_COMMANDS : [])

// Exit on debugger detection in external build
if ("external" !== 'ant' && isBeingDebugged()) {
  process.exit(1)
}
```

---

## 7. Configuration Layers

Settings are merged from 7 layers, bottom to top. Higher layers override lower ones:

```
Priority (high → low):
┌─────────────────────────────────────────────────────┐
│ 7. Policy Limits                                     │
│    - Hard limits set by enterprise administrators    │
│    - Checked via isPolicyAllowed()                   │
│    - loadPolicyLimits() / refreshPolicyLimits()      │
├─────────────────────────────────────────────────────┤
│ 6. Remote Managed Settings                           │
│    - Downloaded from enterprise server               │
│    - isEligibleForRemoteManagedSettings()             │
│    - loadRemoteManagedSettings()                      │
├─────────────────────────────────────────────────────┤
│ 5. MDM (Mobile Device Management)                    │
│    macOS plist (priority order):                     │
│    ├── /Library/Managed Preferences/{user}/com.anthropic.claudecode.plist │
│    ├── /Library/Managed Preferences/com.anthropic.claudecode.plist        │
│    └── ~/Library/Preferences/com.anthropic.claudecode.plist (ant test)    │
│    Command: plutil -convert json -o - -- <path>      │
│    Windows registry:                                 │
│    ├── HKLM\SOFTWARE\Policies\ClaudeCode /v Settings │
│    └── HKCU\SOFTWARE\Policies\ClaudeCode /v Settings │
│    Command: reg query <path> /v Settings (JSON value) │
│    startMdmRawRead() → ensureMdmSettingsLoaded()     │
├─────────────────────────────────────────────────────┤
│ 4. CLI Flags (command-line options)                   │
│    - --settings <file|json>                          │
│    - --setting-sources <sources>                     │
│    - --model, --permission-mode, --allowedTools, etc.│
├─────────────────────────────────────────────────────┤
│ 3. Settings JSON (settings files)                    │
│    Per-source loading (getSettingsForSource):         │
│    ├── policySettings (managed-settings.json/policy) │
│    ├── flagSettings (--settings CLI flag file)       │
│    ├── userSettings (~/.claude/settings.json)        │
│    ├── projectSettings (.claude/settings.json)       │
│    └── localSettings (.claude/settings.local.json)   │
├─────────────────────────────────────────────────────┤
│ 2. Project Config (.claude/config.json)              │
│    - Per-project settings (MCP servers, agents, etc.)│
├─────────────────────────────────────────────────────┤
│ 1. Global Config (~/.claude/config.json)             │
│    - getGlobalConfig() / saveGlobalConfig()          │
│    - verbose, migrationVersion, hasTrustDialogAccepted│
│    - theme, vimMode, and other user preferences      │
└─────────────────────────────────────────────────────┘
```

### 7.1 Settings JSON Structure

```typescript
// utils/settings/types.ts - SettingsJson type
type SettingsJson = {
  // Environment variables
  env?: Record<string, string>

  // Permissions
  permissions?: {
    allow?: ToolPermissionRule[]
    deny?: ToolPermissionRule[]
  }

  // MCP servers
  mcpServers?: Record<string, McpServerConfig>

  // Model
  model?: string
  smallFastModel?: string

  // Behavior
  prefersReducedMotion?: boolean
  theme?: string
  defaultMode?: PermissionMode

  // Hooks
  hooks?: Record<string, HookConfig[]>

  // Plugins
  plugins?: PluginConfig[]

  // Agents
  agents?: Record<string, AgentConfig>

  // ... many additional settings keys
}
```

### 7.2 Environment Variable Application Order

```
init()
├── applySafeConfigEnvironmentVariables()  // Before trust: safe variables only
│   └── ANTHROPIC_API_KEY, ANTHROPIC_BASE_URL, proxy, etc.
└── (After trust confirmation)
    └── applyConfigEnvironmentVariables()  // Full: apply env block from settings.json
```

---

## 8. State Management

### 8.1 Store Pattern

A minimal state management system defined in `src/state/store.ts`:

```typescript
// state/store.ts - Pure state management without React dependency

type Store<T> = {
  getState: () => T
  setState: (updater: (prev: T) => T) => void
  subscribe: (listener: Listener) => () => void
}

function createStore<T>(
  initialState: T,
  onChange?: OnChange<T>,
): Store<T> {
  let state = initialState
  const listeners = new Set<Listener>()

  return {
    getState: () => state,

    setState: (updater) => {
      const prev = state
      const next = updater(prev)
      if (Object.is(next, prev)) return  // Reference equality check
      state = next
      onChange?.({ newState: next, oldState: prev })
      for (const listener of listeners) listener()
    },

    subscribe: (listener) => {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
  }
}
```

**Key characteristics**:
- `Object.is()` comparison prevents unnecessary updates
- `onChange` callback for side effect execution (`onChangeAppState`)
- `subscribe` enables subscriptions from outside React
- React connection via `useSyncExternalStore` (AppState.tsx)

### 8.2 AppState Structure

`AppState` is the immutable central state object for the entire application:

```typescript
// state/AppStateStore.ts - DeepImmutable<{...}>

type AppState = DeepImmutable<{
  // Settings
  settings: SettingsJson
  verbose: boolean
  mainLoopModel: ModelSetting
  mainLoopModelForSession: ModelSetting

  // UI state
  statusLineText: string | undefined
  expandedView: 'none' | 'tasks' | 'teammates'
  isBriefOnly: boolean
  viewSelectionMode: 'none' | 'selecting-agent' | 'viewing-agent'
  footerSelection: FooterItem | null
  spinnerTip?: string
  kairosEnabled: boolean

  // Permissions
  toolPermissionContext: ToolPermissionContext

  // Agent/session
  agent: string | undefined
  remoteSessionUrl: string | undefined
  remoteConnectionStatus: 'connecting' | 'connected' | ...

  // Bridge
  replBridgeEnabled: boolean
  replBridgeConnected: boolean
  replBridgeSessionUrl: string | undefined
  // ... 10+ bridge-related fields
}> & {
  // Areas excluded from DeepImmutable (contain function types)
  tasks: { [taskId: string]: TaskState }
  agentNameRegistry: Map<string, AgentId>
  foregroundedTaskId?: string
  viewingAgentTaskId?: string
  companionReaction?: string

  // MCP runtime state
  mcp: {
    clients: MCPServerConnection[]
    tools: Tool[]
    commands: Command[]
    resources: Record<string, ServerResource[]>
    pluginReconnectKey: number
  }

  // Plugin runtime state
  plugins: {
    enabled: LoadedPlugin[]
    disabled: LoadedPlugin[]
    commands: Command[]
    errors: PluginError[]
    installationStatus: { ... }
  }

  // Speculative execution
  speculation: SpeculationState
  // ... many additional runtime state fields
}
```

### 8.3 React Context Connection

```typescript
// state/AppState.tsx

// Provide Store via React Context
export const AppStoreContext = React.createContext<AppStateStore | null>(null)

function AppStateProvider({ children, initialState, onChangeAppState }) {
  const store = createStore(initialState ?? getDefaultAppState(), onChangeAppState)

  return (
    <HasAppStateContext.Provider value={true}>
      <AppStoreContext.Provider value={store}>
        <MailboxProvider>
          <VoiceProvider>
            {children}
          </VoiceProvider>
        </MailboxProvider>
      </AppStoreContext.Provider>
    </HasAppStateContext.Provider>
  )
}
```

### 8.4 Async Context for Subagents

Subagents (AgentTool) receive a separate `ToolUseContext`. To prevent concurrently running agents from polluting each other's state, `createSubagentContext()` handles the following:

```
Main Thread Store
    │
    ├─ Agent A (ToolUseContext)
    │   ├─ setAppState → no-op (subagents cannot modify root state)
    │   ├─ setAppStateForTasks → root Store (only task infrastructure allowed)
    │   ├─ readFileState → cloned FileStateCache
    │   ├─ contentReplacementState → cloned
    │   └─ localDenialTracking → independent denial tracking
    │
    └─ Agent B (ToolUseContext)
        ├─ setAppState → no-op
        ├─ setAppStateForTasks → root Store
        └─ ... (independent state)
```

### 8.5 bootstrap/state.ts: Global Singleton State

`bootstrap/state.ts` manages global state that persists for the process lifetime. Managed via module-scope variables (not the Store pattern), accessed through getter/setter functions:

```typescript
// bootstrap/state.ts (excerpt)
type State = {
  originalCwd: string
  projectRoot: string
  sessionId: SessionId
  isInteractive: boolean
  clientType: string
  initialMainLoopModel: string | null
  sdkBetas: string[]
  allowedSettingSources: SettingSource[] | null
  kairosActive: boolean
  // ... 110 global state fields (full list: Doc 07 Section 3)
}

// Access pattern
export function getSessionId(): SessionId { ... }
export function setIsInteractive(v: boolean): void { ... }
export function getCwd(): string { ... }
```

**Key principle**: The `bootstrap/state.ts` comments explicitly state "DO NOT ADD MORE STATE HERE - BE JUDICIOUS WITH GLOBAL STATE". Adding new global state should be done with caution.

---

## Appendix: Key Type References

### Tool Type (Tool.ts)

```typescript
type Tool<Input, Output, P> = {
  name: string
  aliases?: string[]
  searchHint?: string
  inputSchema: Input           // Zod v4 schema
  inputJSONSchema?: ToolInputJSONSchema  // JSON Schema for MCP tools
  outputSchema?: z.ZodType<unknown>
  maxResultSizeChars: number
  shouldDefer?: boolean        // Whether ToolSearch is required
  alwaysLoad?: boolean         // Always load (never deferred)
  isMcp?: boolean
  strict?: boolean

  // Lifecycle methods
  call(args, context, canUseTool, parentMessage, onProgress?): Promise<ToolResult<Output>>
  validateInput?(input, context): Promise<ValidationResult>
  checkPermissions(input, context): Promise<PermissionResult>
  description(input, options): Promise<string>
  prompt(options): Promise<string>

  // Property methods
  isEnabled(): boolean
  isConcurrencySafe(input): boolean
  isReadOnly(input): boolean
  isDestructive?(input): boolean
  interruptBehavior?(): 'cancel' | 'block'

  // Rendering methods
  renderToolUseMessage(input, options): React.ReactNode
  renderToolResultMessage?(content, progress, options): React.ReactNode
  renderToolUseProgressMessage?(progress, options): React.ReactNode
  renderGroupedToolUse?(toolUses, options): React.ReactNode | null
  // ... 10+ additional rendering methods
}
```

### buildTool() Factory

```typescript
// Converts a tool definition into a complete Tool object
// Defaults: isEnabled=true, isConcurrencySafe=false, isReadOnly=false,
//           isDestructive=false, checkPermissions=allow, userFacingName=name
function buildTool<D extends AnyToolDef>(def: D): BuiltTool<D> {
  return {
    ...TOOL_DEFAULTS,
    userFacingName: () => def.name,
    ...def,
  }
}
```

### QueryEngineConfig

```typescript
type QueryEngineConfig = {
  cwd: string
  tools: Tools
  commands: Command[]
  mcpClients: MCPServerConnection[]
  agents: AgentDefinition[]
  canUseTool: CanUseToolFn
  getAppState: () => AppState
  setAppState: (f: (prev: AppState) => AppState) => void
  initialMessages?: Message[]
  readFileCache: FileStateCache
  customSystemPrompt?: string
  appendSystemPrompt?: string
  userSpecifiedModel?: string
  fallbackModel?: string
  thinkingConfig?: ThinkingConfig
  maxTurns?: number
  maxBudgetUsd?: number
  taskBudget?: { total: number }
  jsonSchema?: Record<string, unknown>
  verbose?: boolean
  replayUserMessages?: boolean
  handleElicitation?: ToolUseContext['handleElicitation']
  includePartialMessages?: boolean
  setSDKStatus?: (status: SDKStatus) => void
  abortController?: AbortController
  orphanedPermission?: OrphanedPermission
  snipReplay?: (msg: Message, store: Message[]) => { ... } | undefined
}
```

---

## Implementation Caveats

### C1. Prefetch-REPL Race Condition
`startDeferredPrefetches()` runs asynchronously after REPL rendering. When a tool depends on prefetch results (getUserContext, prefetchSystemContextIfSafe, etc.), the data may not yet be loaded. **Do not assume prefetch completion** — a synchronous fallback is required on cache miss.

### C2. Migration Partial Failure
`runMigrations()` runs sequentially but without try-catch. If migration 5 throws, migrations 1-4 are committed while 6-11 are skipped. The settings file can end up in a half-applied state. Each migration must be independently idempotent.

### C3. Analytics Circular Dependency Rule
`src/services/analytics/` **must not import any service**. Since all services import analytics, if analytics imports a service, a circular reference occurs. This rule exists only implicitly in the code and is not enforced by a linter.

### C4. Tool Count Notation: "30+" vs "45+"
Doc 01's "30+ built-in tools" counts only the core base tools, while Doc 02's "45+" is the full count including feature-gated tools. All 45+ tools must be registered during implementation.
