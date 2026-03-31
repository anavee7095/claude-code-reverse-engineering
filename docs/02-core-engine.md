# Part 2: Core Engine Design

> Reverse engineering design document for the Claude Code CLI core execution engine
> Source: `src/Tool.ts`, `src/tools.ts`, `src/commands.ts`, `src/QueryEngine.ts`, `src/query.ts`, `src/services/tools/toolExecution.ts`, `src/services/tools/StreamingToolExecutor.ts`, `src/services/api/withRetry.ts`, `src/services/api/claude.ts`, `src/cost-tracker.ts`

---

## Table of Contents

1. [Tool Type System](#1-tool-type-system)
2. [QueryEngine Class](#2-queryengine-class)
3. [Query Execution Loop](#3-query-execution-loop-queryts)
4. [Tool Execution Pipeline](#4-tool-execution-pipeline-toolexecutionts)
5. [Streaming Tool Executor](#5-streaming-tool-executor)
6. [Command System](#6-command-system)
7. [Retry Logic](#7-retry-logic-withretryts)
8. [Cost Tracking](#8-cost-tracking)

---

## 1. Tool Type System

### 1.1 Tool<In, Out, Progress> Interface

The Tool interface is the core type that defines the shape of all tools in Claude Code. It uses 3 generic parameters and includes over 60 fields/methods.

```typescript
// Base type for input schemas - Zod-based object schema
type AnyObject = z.ZodType<{ [key: string]: unknown }>

type Tool<
  Input extends AnyObject = AnyObject,
  Output = unknown,
  P extends ToolProgressData = ToolProgressData,
> = {
  // === Identification ===
  readonly name: string                          // Unique tool name (e.g., "Bash", "Read")
  aliases?: string[]                             // Backward-compatible aliases (e.g., "KillShell" -> "TaskStop")
  searchHint?: string                            // ToolSearch keyword matching hint (3-10 words)

  // === Schema ===
  readonly inputSchema: Input                    // Zod input schema
  readonly inputJSONSchema?: ToolInputJSONSchema  // Direct JSON Schema specification for MCP tools
  outputSchema?: z.ZodType<unknown>              // Output schema (optional)

  // === Core Methods ===
  call(
    args: z.infer<Input>,
    context: ToolUseContext,
    canUseTool: CanUseToolFn,
    parentMessage: AssistantMessage,
    onProgress?: ToolCallProgress<P>,
  ): Promise<ToolResult<Output>>

  description(
    input: z.infer<Input>,
    options: {
      isNonInteractiveSession: boolean
      toolPermissionContext: ToolPermissionContext
      tools: Tools
    },
  ): Promise<string>

  prompt(options: {
    getToolPermissionContext: () => Promise<ToolPermissionContext>
    tools: Tools
    agents: AgentDefinition[]
    allowedAgentTypes?: string[]
  }): Promise<string>

  // === Permission/Validation ===
  validateInput?(input: z.infer<Input>, context: ToolUseContext): Promise<ValidationResult>
  checkPermissions(input: z.infer<Input>, context: ToolUseContext): Promise<PermissionResult>
  preparePermissionMatcher?(input: z.infer<Input>): Promise<(pattern: string) => boolean>

  // === Concurrency/Safety ===
  isConcurrencySafe(input: z.infer<Input>): boolean     // false: exclusive execution required
  isReadOnly(input: z.infer<Input>): boolean             // true: read-only operation
  isDestructive?(input: z.infer<Input>): boolean         // true: irreversible operation (delete, overwrite)
  isEnabled(): boolean                                    // Feature gate/environment activation
  interruptBehavior?(): 'cancel' | 'block'               // Behavior on user new message

  // === MCP/Special Flags ===
  isMcp?: boolean                      // Whether this is an MCP server tool
  isLsp?: boolean                      // Whether this is an LSP tool
  readonly shouldDefer?: boolean       // Deferred loading via ToolSearch
  readonly alwaysLoad?: boolean        // Exception to deferred loading (always load)
  mcpInfo?: { serverName: string; toolName: string }  // MCP original name info
  readonly strict?: boolean            // Strict mode (API enforces schema compliance more strongly)

  // === Result Size Control ===
  maxResultSizeChars: number           // Exceeding saves to disk and returns preview
                                       // Infinity: never save (Read, etc.)

  // === Input Transformation ===
  backfillObservableInput?(input: Record<string, unknown>): void
  // Called only on clones. Original API input is immutable for prompt cache preservation.
  // Adds legacy/derived fields visible to hooks/SDK/transcripts.

  // === UI Rendering (React) ===
  userFacingName(input: Partial<z.infer<Input>> | undefined): string
  userFacingNameBackgroundColor?(input): keyof Theme | undefined
  isTransparentWrapper?(): boolean
  getToolUseSummary?(input): string | null
  getActivityDescription?(input): string | null       // For spinner display (e.g., "Reading src/foo.ts")
  renderToolUseMessage(input, options): React.ReactNode
  renderToolResultMessage?(content, progressMessages, options): React.ReactNode
  renderToolUseProgressMessage?(progressMessages, options): React.ReactNode
  renderToolUseRejectedMessage?(input, options): React.ReactNode
  renderToolUseErrorMessage?(result, options): React.ReactNode
  renderToolUseQueuedMessage?(): React.ReactNode
  renderToolUseTag?(input): React.ReactNode
  renderGroupedToolUse?(toolUses, options): React.ReactNode | null
  isResultTruncated?(output: Output): boolean
  extractSearchText?(out: Output): string              // For transcript search indexing

  // === Classification/Analysis ===
  toAutoClassifierInput(input: z.infer<Input>): unknown
  mapToolResultToToolResultBlockParam(content: Output, toolUseID: string): ToolResultBlockParam
  isSearchOrReadCommand?(input): { isSearch: boolean; isRead: boolean; isList?: boolean }
  isOpenWorld?(input): boolean
  requiresUserInteraction?(): boolean
  getPath?(input): string                              // For file-path-based tools

  // === Input Equivalence Comparison ===
  inputsEquivalent?(a: z.infer<Input>, b: z.infer<Input>): boolean
}
```

### 1.2 ValidationResult Discriminated Union

```typescript
type ValidationResult =
  | { result: true }                               // Validation passed
  | { result: false; message: string; errorCode: number }  // Validation failed + reason
```

### 1.2.1 ToolResult Type

```typescript
// src/Tool.ts:321-336
type ToolResult<T> = {
  data: T                           // Tool execution result (generic T)
  newMessages?: (                   // Additional messages (inserted into conversation context)
    | UserMessage
    | AssistantMessage
    | AttachmentMessage
    | SystemMessage
  )[]
  // contextModifier is only applied for isConcurrencySafe=false tools
  contextModifier?: (context: ToolUseContext) => ToolUseContext
  /** MCP protocol metadata — passed to SDK consumers */
  mcpMeta?: {
    _meta?: Record<string, unknown>
    structuredContent?: Record<string, unknown>
  }
}
```

**mcpMeta**: Only included in MCP tool execution results. `mapToolResultToToolResultBlockParam()` reads this metadata to correctly pass MCP server context to Claude API requests.
**contextModifier**: Only applied for non-concurrency-safe tools. Modifies ToolUseContext after tool execution, affecting subsequent tools.
**newMessages**: Tools can insert additional messages (User/Assistant/Attachment/System) into the conversation.

### 1.2.2 ToolDef Type

The definition object type passed to the `buildTool()` factory. Makes the 7 `DefaultableToolKeys` optional while keeping the rest as required from `Tool<I, O, P>`.

```typescript
// src/Tool.ts:707-726
type DefaultableToolKeys =
  | 'isEnabled'
  | 'isConcurrencySafe'
  | 'isReadOnly'
  | 'isDestructive'
  | 'checkPermissions'
  | 'toAutoClassifierInput'
  | 'userFacingName'

type ToolDef<I, O, P> = Omit<Tool<I, O, P>, DefaultableToolKeys>
  & Partial<Pick<Tool<I, O, P>, DefaultableToolKeys>>

type AnyToolDef = ToolDef<any, any, any>

// Practical usage: buildTool({ name, description, inputSchema, call, ...overrides })
// Required: name, description, inputSchema, call + other non-defaultable keys
// Optional: 7 DefaultableToolKeys (safe defaults from TOOL_DEFAULTS)
```

### 1.3 ToolUseContext (30+ Fields)

Context object passed to every tool invocation. Encapsulates the full conversation state, app state, subscriptions/callbacks.

```typescript
type ToolUseContext = {
  // === Options ===
  options: {
    commands: Command[]
    debug: boolean
    mainLoopModel: string
    tools: Tools
    verbose: boolean
    thinkingConfig: ThinkingConfig
    mcpClients: MCPServerConnection[]
    mcpResources: Record<string, ServerResource[]>
    isNonInteractiveSession: boolean
    agentDefinitions: AgentDefinitionsResult
    maxBudgetUsd?: number
    customSystemPrompt?: string
    appendSystemPrompt?: string
    querySource?: QuerySource
    refreshTools?: () => Tools          // Tool refresh callback on mid-session MCP server connection
  }

  // === State Management ===
  abortController: AbortController
  readFileState: FileStateCache
  getAppState(): AppState
  setAppState(f: (prev: AppState) => AppState): void
  setAppStateForTasks?: (f: (prev: AppState) => AppState) => void
  // ^--- Async agent's setAppState is a no-op, so separate setter for session-scope infrastructure

  // === UI Callbacks ===
  setToolJSX?: SetToolJSXFn
  addNotification?: (notif: Notification) => void
  appendSystemMessage?: (msg: SystemMessage) => void
  sendOSNotification?: (opts: { message: string; notificationType: string }) => void
  setStreamMode?: (mode: SpinnerMode) => void
  onCompactProgress?: (event: CompactProgressEvent) => void
  setSDKStatus?: (status: SDKStatus) => void
  openMessageSelector?: () => void

  // === Progress Tracking ===
  setInProgressToolUseIDs: (f: (prev: Set<string>) => Set<string>) => void
  setHasInterruptibleToolInProgress?: (v: boolean) => void
  setResponseLength: (f: (prev: number) => number) => void
  pushApiMetricsEntry?: (ttftMs: number) => void

  // === State Updates ===
  updateFileHistoryState: (updater: (prev: FileHistoryState) => FileHistoryState) => void
  updateAttributionState: (updater: (prev: AttributionState) => AttributionState) => void
  setConversationId?: (id: UUID) => void

  // === Agent Info ===
  agentId?: AgentId           // Subagent only
  agentType?: string          // Subagent type name

  // === Conversation State ===
  messages: Message[]
  fileReadingLimits?: { maxTokens?: number; maxSizeBytes?: number }
  globLimits?: { maxResults?: number }
  toolDecisions?: Map<string, { source: string; decision: 'accept' | 'reject'; timestamp: number }>
  queryTracking?: QueryChainTracking     // { chainId: string; depth: number }
  toolUseId?: string

  // === Memory/Skills ===
  nestedMemoryAttachmentTriggers?: Set<string>
  loadedNestedMemoryPaths?: Set<string>
  dynamicSkillDirTriggers?: Set<string>
  discoveredSkillNames?: Set<string>

  // === Advanced ===
  userModified?: boolean
  requireCanUseTool?: boolean            // Forced when speculation overlay rewrites paths
  requestPrompt?: (sourceName: string, toolInputSummary?: string | null) =>
    (request: PromptRequest) => Promise<PromptResponse>
  criticalSystemReminder_EXPERIMENTAL?: string
  preserveToolUseResults?: boolean
  localDenialTracking?: DenialTrackingState
  contentReplacementState?: ContentReplacementState
  renderedSystemPrompt?: SystemPrompt     // Cache for fork subagent
  handleElicitation?: (serverName, params, signal) => Promise<ElicitResult>
}
```

### 1.4 ToolPermissionContext

Uses the `DeepImmutable<T>` wrapper to guarantee immutability of the permission context.

```typescript
type ToolPermissionContext = DeepImmutable<{
  mode: PermissionMode                    // 'default' | 'auto' | 'plan' | 'bypassPermissions'
  additionalWorkingDirectories: Map<string, AdditionalWorkingDirectory>
  alwaysAllowRules: ToolPermissionRulesBySource
  alwaysDenyRules: ToolPermissionRulesBySource
  alwaysAskRules: ToolPermissionRulesBySource
  isBypassPermissionsModeAvailable: boolean
  isAutoModeAvailable?: boolean
  strippedDangerousRules?: ToolPermissionRulesBySource
  shouldAvoidPermissionPrompts?: boolean   // Background agent (cannot display UI)
  awaitAutomatedChecksBeforeDialog?: boolean  // Coordinator workers
  prePlanMode?: PermissionMode             // Preserved state before plan mode entry
}>

// Empty initial value factory
const getEmptyToolPermissionContext: () => ToolPermissionContext = () => ({
  mode: 'default',
  additionalWorkingDirectories: new Map(),
  alwaysAllowRules: {},
  alwaysDenyRules: {},
  alwaysAskRules: {},
  isBypassPermissionsModeAvailable: false,
})
```

### 1.5 buildTool() Factory and TOOL_DEFAULTS

All tool definitions are converted to complete `Tool` objects via `buildTool()`. Defaults are managed in one place, eliminating the need for `?.() ?? default` patterns at call sites.

```typescript
// List of keys that receive defaults
type DefaultableToolKeys =
  | 'isEnabled'           // () => true
  | 'isConcurrencySafe'   // () => false (assumed unsafe)
  | 'isReadOnly'          // () => false (assumed writable)
  | 'isDestructive'       // () => false
  | 'checkPermissions'    // allow + updatedInput return (delegates to general permission system)
  | 'toAutoClassifierInput' // () => '' (security-related tools must override)
  | 'userFacingName'      // () => name

const TOOL_DEFAULTS = {
  isEnabled: () => true,
  isConcurrencySafe: (_input?) => false,       // fail-closed
  isReadOnly: (_input?) => false,              // fail-closed
  isDestructive: (_input?) => false,
  checkPermissions: (input, _ctx?) =>
    Promise.resolve({ behavior: 'allow', updatedInput: input }),
  toAutoClassifierInput: (_input?) => '',
  userFacingName: (_input?) => '',
}

// Type-level spread: { ...TOOL_DEFAULTS, ...def }
function buildTool<D extends AnyToolDef>(def: D): BuiltTool<D> {
  return {
    ...TOOL_DEFAULTS,
    userFacingName: () => def.name,   // Default based on name
    ...def,                            // User definition overrides
  } as BuiltTool<D>
}
```

### 1.6 Tool Registry (tools.ts)

#### Complete Tool List and Categories

45+ tools conditionally included by `getAllBaseTools()` based on environment/feature gates:

| Category | Tool | Conditional |
|----------|------|-------------|
| **Core Execution** | `BashTool`, `PowerShellTool` | PowerShell: Windows only |
| **File Operations** | `FileReadTool`, `FileEditTool`, `FileWriteTool`, `NotebookEditTool` | |
| **Search** | `GlobTool`, `GrepTool` | Only when no embedded search tools |
| **Agent** | `AgentTool`, `SkillTool`, `TaskOutputTool`, `TaskStopTool` | |
| **Task Management** | `TaskCreateTool`, `TaskGetTool`, `TaskUpdateTool`, `TaskListTool` | When TodoV2 is enabled |
| **Web** | `WebFetchTool`, `WebSearchTool`, `WebBrowserTool` | WebBrowser: feature gated |
| **MCP** | `ListMcpResourcesTool`, `ReadMcpResourceTool` | |
| **Tool Search** | `ToolSearchTool` | isToolSearchEnabledOptimistic() |
| **Plan Mode** | `EnterPlanModeTool`, `ExitPlanModeV2Tool` | |
| **Worktree** | `EnterWorktreeTool`, `ExitWorktreeTool` | isWorktreeModeEnabled() |
| **Team** | `TeamCreateTool`, `TeamDeleteTool`, `SendMessageTool` | isAgentSwarmsEnabled() |
| **User Interaction** | `AskUserQuestionTool`, `BriefTool` | |
| **Other** | `TodoWriteTool`, `ConfigTool`, `TungstenTool`, `LSPTool` | Various conditions |
| **ant-only** | `REPLTool`, `SuggestBackgroundPRTool` | USER_TYPE=ant |
| **Kairos** | `SleepTool`, `SendUserFileTool`, `PushNotificationTool`, `SubscribePRTool` | Feature gated |
| **Scheduling** | `CronCreateTool`, `CronDeleteTool`, `CronListTool` | AGENT_TRIGGERS |
| **History** | `SnipTool` | HISTORY_SNIP |
| **Infrastructure** | `ListPeersTool`, `WorkflowTool`, `MonitorTool`, `RemoteTriggerTool` | Each feature gated |
| **Test** | `TestingPermissionTool`, `OverflowTestTool` | NODE_ENV=test, feature gated |

#### Tool Pool Assembly Pipeline

```
getAllBaseTools()          All base tools (with environment gates applied)
       │
       ▼
getTools(permCtx)         Deny rule filtering + isEnabled() + REPL mode filtering
       │
       ▼
assembleToolPool(permCtx, mcpTools)
       │  1. Get built-in tools via getTools()
       │  2. Apply deny rule filtering to MCP tools
       │  3. Sort each by name (cache stability)
       │  4. uniqBy(name) for deduplication (built-in tools take priority)
       ▼
  Final Tools array (included in API requests)
```

**Key design decision**: Built-in tools are kept as a sorted prefix to maintain valid server-side cache breakpoints. If MCP tools were interleaved between built-in tools, all downstream cache keys would be invalidated.

---

## 2. QueryEngine Class

### 2.1 Architecture Overview

One `QueryEngine` instance is created per conversation, used by both the SDK/headless path and the REPL. Each `submitMessage()` call starts a new turn within the same conversation.

```
QueryEngine
  ├── config: QueryEngineConfig (immutable)
  ├── mutableMessages: Message[] (accumulated across turns)
  ├── abortController: AbortController
  ├── permissionDenials: SDKPermissionDenial[]
  ├── totalUsage: NonNullableUsage (accumulated on each message_stop)
  ├── discoveredSkillNames: Set<string> (reset per turn)
  └── loadedNestedMemoryPaths: Set<string>
```

### 2.2 QueryEngineConfig Type

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
  jsonSchema?: Record<string, unknown>       // Structured output schema
  verbose?: boolean
  replayUserMessages?: boolean
  handleElicitation?: ToolUseContext['handleElicitation']
  includePartialMessages?: boolean
  setSDKStatus?: (status: SDKStatus) => void
  abortController?: AbortController
  orphanedPermission?: OrphanedPermission
  snipReplay?: (yieldedSystemMsg: Message, store: Message[]) =>
    { messages: Message[]; executed: boolean } | undefined
  // ^--- HISTORY_SNIP feature gate. Callback injection to prevent feature() strings from entering this file
}
```

### 2.3 submitMessage() AsyncGenerator Flow

```
submitMessage(prompt, options?)
  │
  ├─ 1. discoveredSkillNames.clear()
  ├─ 2. setCwd(cwd)
  ├─ 3. Wrap canUseTool (permission denial tracking)
  ├─ 4. Model determination (userSpecifiedModel || getMainLoopModel())
  ├─ 5. ThinkingConfig determination
  │
  ├─ 6. fetchSystemPromptParts() ← system prompt composition
  │     ├── defaultSystemPrompt (base)
  │     ├── memoryMechanicsPrompt (when CLAUDE_COWORK_MEMORY_PATH_OVERRIDE)
  │     └── appendSystemPrompt (additional)
  │
  ├─ 7. processUserInput()
  │     ├── Slash command interpretation
  │     ├── shouldQuery determination
  │     ├── allowedTools collection
  │     └── Model override return
  │
  ├─ 8. mutableMessages.push(...messagesFromUserInput)
  ├─ 9. recordTranscript() (session persistence)
  │
  ├─ 10. yield buildSystemInitMessage() ← SDK initialization message
  │
  ├─ 11. if (!shouldQuery): yield local command result → return
  │
  ├─ 12. for await (message of query({...})):
  │       ├── assistant → mutableMessages.push + yield* normalizeMessage
  │       ├── progress → mutableMessages.push + recordTranscript
  │       ├── user → turnCount++ + mutableMessages.push
  │       ├── stream_event:
  │       │     ├── message_start → currentMessageUsage initialization
  │       │     ├── message_delta → usage update + stop_reason capture
  │       │     └── message_stop → totalUsage accumulation
  │       ├── attachment:
  │       │     ├── structured_output → result capture
  │       │     ├── max_turns_reached → error result yield + return
  │       │     └── queued_command → SDK replay
  │       ├── system:
  │       │     ├── snip_boundary → mutableMessages trimming
  │       │     ├── compact_boundary → GC release + SDK pass-through
  │       │     └── api_error → SDK retry message
  │       └── tool_use_summary → SDK pass-through
  │
  ├─ 13. Budget exceeded check (maxBudgetUsd, structured output retry limit)
  │
  └─ 14. Final result yield:
        ├── isResultSuccessful() → success result
        └── !isResultSuccessful() → error_during_execution + watermark-based error scope
```

### 2.4 Token Counting and Usage Tracking

```typescript
// Per-message usage (reset on each message_start)
let currentMessageUsage: NonNullableUsage = EMPTY_USAGE

// stream_event handling:
// message_start → currentMessageUsage = updateUsage(EMPTY, event.message.usage)
// message_delta → currentMessageUsage = updateUsage(current, event.usage)
// message_stop → totalUsage = accumulateUsage(totalUsage, currentMessageUsage)

// updateUsage(): replaces a single message's usage with the latest values
// accumulateUsage(): accumulates into the session-wide total
```

### 2.5 Feature-Gated Imports

Modules in `QueryEngine.ts` that use `feature()` gates:

| Feature Gate | Module | Purpose |
|-------------|--------|---------|
| `HISTORY_SNIP` | `snipCompact.js`, `snipProjection.js` | History trimming |
| `COORDINATOR_MODE` | `coordinatorMode.js` | Coordinator user context |

These are conditional imports via `require()` and are dead code elimination targets at build time.

---

## 3. Query Execution Loop (query.ts)

### 3.1 State Machine Architecture

`queryLoop()` is a `while(true)`-based state machine where each iteration processes one "turn."

```typescript
// Mutable state passed between iterations
type State = {
  messages: Message[]
  toolUseContext: ToolUseContext
  autoCompactTracking: AutoCompactTrackingState | undefined
  maxOutputTokensRecoveryCount: number        // OTK recovery count (max 3)
  hasAttemptedReactiveCompact: boolean        // Whether reactive compact was attempted
  maxOutputTokensOverride: number | undefined // OTK escalation value
  pendingToolUseSummary: Promise<ToolUseSummaryMessage | null> | undefined
  stopHookActive: boolean | undefined
  turnCount: number
  transition: Continue | undefined            // Continue reason from previous iteration
}
```

### 3.2 Continue Transition Types

```typescript
// All continue reasons are explicitly tracked
type Continue =
  | { reason: 'next_turn' }                    // Normal progression after tool use
  | { reason: 'collapse_drain_retry'; committed: number }
  | { reason: 'reactive_compact_retry' }
  | { reason: 'max_output_tokens_escalate' }
  | { reason: 'max_output_tokens_recovery'; attempt: number }
  | { reason: 'stop_hook_blocking' }
  | { reason: 'token_budget_continuation' }

type Terminal =
  | { reason: 'completed' }
  | { reason: 'aborted_streaming' }
  | { reason: 'aborted_tools' }
  | { reason: 'hook_stopped' }
  | { reason: 'stop_hook_prevented' }
  | { reason: 'blocking_limit' }
  | { reason: 'prompt_too_long' }
  | { reason: 'image_error' }
  | { reason: 'model_error'; error?: unknown }
  | { reason: 'max_turns'; turnCount: number }
```

### 3.3 8-Stage Recovery Chain

Recovery strategies attempted sequentially when errors occur:

```
1. Streaming Fallback
   ├── FallbackTriggeredError during streaming
   ├── Reset assistantMessages + yield tombstone
   ├── Switch model to fallbackModel
   ├── Remove signature blocks (thinking signature conflict prevention)
   └── attemptWithFallback = true → retry

2. Model Fallback
   ├── FallbackTriggeredError catch
   ├── currentModel = fallbackModel
   └── continue (retry with same messages)

3. Collapse Drain (context reduction drain)
   ├── Condition: withheld 413 + CONTEXT_COLLAPSE active + previous transition ≠ collapse_drain
   ├── contextCollapse.recoverFromOverflow() call
   ├── committed > 0 → transition: 'collapse_drain_retry'
   └── committed == 0 → proceed to next stage

4. Reactive Compact
   ├── Condition: withheld 413/media + !hasAttemptedReactiveCompact
   ├── reactiveCompact.tryReactiveCompact() call
   ├── Success → postCompactMessages + transition: 'reactive_compact_retry'
   ├── hasAttemptedReactiveCompact = true (one-time)
   └── Failure → yield withheld error + terminate

5. OTK Escalation (Output Token Escalation)
   ├── Condition: max_output_tokens error + no override
   ├── maxOutputTokensOverride = ESCALATED_MAX_TOKENS (64k)
   └── transition: 'max_output_tokens_escalate' (retry same request)

6. OTK Recovery (Output Token Recovery)
   ├── Condition: max_output_tokens after escalation
   ├── Inject recovery message: "Resume directly, no recap..."
   ├── maxOutputTokensRecoveryCount++ (max 3)
   └── transition: 'max_output_tokens_recovery'

7. Stop Hook Blocking
   ├── handleStopHooks() returns blockingErrors
   ├── Add blocking errors to messages
   ├── stopHookActive = true
   └── transition: 'stop_hook_blocking'

8. Token Budget Continuation
   ├── Condition: TOKEN_BUDGET feature + checkTokenBudget() → 'continue'
   ├── Inject nudge message
   ├── incrementBudgetContinuationCount()
   └── transition: 'token_budget_continuation'
```

### 3.4 Circuit Breakers

```typescript
const MAX_OUTPUT_TOKENS_RECOVERY_LIMIT = 3  // Maximum OTK recovery attempts

// Circuit breakers within State:
hasAttemptedReactiveCompact: boolean  // Reactive compact limited to 1 per turn
maxOutputTokensRecoveryCount: number  // Starts at 0, surfaces error when reaching 3

// Reset timing:
// - next_turn: both counters reset to 0
// - stop_hook_blocking: maxOutputTokensRecoveryCount = 0,
//                       hasAttemptedReactiveCompact retained (infinite loop prevention)
```

### 3.5 Watermark-Based Error Scoping

```typescript
// Snapshot at query start
const errorLogWatermark = getInMemoryErrors().at(-1)

// When collecting errors in results: include only errors after watermark
const all = getInMemoryErrors()
const start = errorLogWatermark ? all.lastIndexOf(errorLogWatermark) + 1 : 0
const turnErrors = all.slice(start).map(_ => _.error)
// Previously: dumped entire process error buffer → included unrelated errors like ripgrep timeouts
```

### 3.6 Turn Processing Pseudocode

```
queryLoop(params):
  state = initial State
  budgetTracker = TOKEN_BUDGET ? createBudgetTracker() : null

  while (true):
    // 1. State destructuring
    { messages, toolUseContext, ... } = state

    // 2. Start skill prefetch (non-blocking)
    pendingSkillPrefetch = startSkillDiscoveryPrefetch()

    // 3. Message preprocessing
    messagesForQuery = getMessagesAfterCompactBoundary(messages)
    messagesForQuery = applyToolResultBudget(messagesForQuery, ...)
    messagesForQuery = snipCompactIfNeeded(messagesForQuery)  // HISTORY_SNIP
    messagesForQuery = microcompact(messagesForQuery, ...)
    messagesForQuery = applyCollapsesIfNeeded(messagesForQuery, ...)  // CONTEXT_COLLAPSE

    // 4. Auto-compaction
    { compactionResult } = autocompact(messagesForQuery, ...)
    if (compactionResult):
      yield* postCompactMessages
      messagesForQuery = postCompactMessages

    // 5. Blocking limit check (when auto-compact OFF + reactive compact OFF)
    if (isAtBlockingLimit):
      yield PROMPT_TOO_LONG_ERROR
      return { reason: 'blocking_limit' }

    // 6. API streaming call
    for await (message of callModel(...)):
      // Streaming fallback handling
      // backfillObservableInput application
      // Withheld message handling (PTL, media, OTK)
      // assistant → add to assistantMessages
      // tool_use block → add to StreamingToolExecutor
      // Collect completed tool results

    // 7. Abort check
    if (aborted):
      yield* remaining tool results / abort messages
      return { reason: 'aborted_streaming' | 'aborted_tools' }

    // 8. Termination without tool use (!needsFollowUp):
    //    8a. 413 recovery chain (collapse drain → reactive compact)
    //    8b. OTK recovery chain (escalate → recovery message)
    //    8c. Stop Hook handling
    //    8d. Token Budget check
    //    → return { reason: 'completed' } or continue

    // 9. Tool execution
    for await (update of streamingToolExecutor.getRemainingResults()):
      yield update.message
      toolResults.push(...)

    // 10. Attachment message collection (memory, skills, queued commands)
    yield* getAttachmentMessages(...)
    yield* memoryPrefetch results
    yield* skillDiscoveryPrefetch results

    // 11. maxTurns check
    if (nextTurnCount > maxTurns):
      yield max_turns_reached
      return { reason: 'max_turns' }

    // 12. Continue to next turn
    state = {
      messages: [...messagesForQuery, ...assistantMessages, ...toolResults],
      turnCount: nextTurnCount,
      transition: { reason: 'next_turn' },
      ...
    }
```

---

## 4. Tool Execution Pipeline (toolExecution.ts)

### 4.1 Execution Stages (8 stages)

```
runToolUse(toolUse, assistantMessage, canUseTool, toolUseContext)
  │
  ├─ 1. Lookup (tool lookup)
  │     ├── findToolByName(tools, name) — search available tools
  │     ├── On failure, fall back to aliases in getAllBaseTools()
  │     └── Not found → "No such tool" error return
  │
  ├─ 2. Schema Validation (Zod schema validation)
  │     ├── tool.inputSchema.safeParse(input)
  │     ├── On failure, formatZodValidationError()
  │     └── Deferred tool + not found → buildSchemaNotSentHint() added
  │
  ├─ 3. Custom Validate (tool-specific custom validation)
  │     ├── tool.validateInput?(parsedInput.data, toolUseContext)
  │     └── On failure, { result: false, message, errorCode } returned
  │
  ├─ 4. Pre-Hook (PreToolUse hook execution)
  │     ├── runPreToolUseHooks() — parallel execution
  │     ├── Result types:
  │     │   ├── message → added to resultingMessages
  │     │   ├── hookPermissionResult → hook permission result captured
  │     │   ├── hookUpdatedInput → processedInput updated
  │     │   ├── preventContinuation → continuation prevention flag
  │     │   ├── stopReason → stop reason
  │     │   └── stop → immediate return
  │     └── PreToolUse timing summary shown when exceeding 500ms
  │
  ├─ 5. Permission (permission decision)
  │     ├── resolveHookPermissionDecision()
  │     │   ├── Use hookPermissionResult if available
  │     │   └── Otherwise call canUseTool()
  │     ├── On denial:
  │     │   ├── Return tool_result is_error
  │     │   ├── Execute PermissionDenied hook (on auto mode classifier denial)
  │     │   └── hookSaysRetry → "retry approved" message
  │     └── OTel tool_decision event emitted
  │
  ├─ 6. Execute (tool execution)
  │     ├── Resolve callInput vs processedInput duality
  │     ├── tool.call(callInput, context, canUseTool, assistantMessage, onProgress)
  │     ├── Result: ToolResult<Output>
  │     │   ├── data: tool output
  │     │   ├── newMessages?: additional messages
  │     │   ├── contextModifier?: context modifier
  │     │   └── mcpMeta?: MCP protocol metadata
  │     └── On error: formatError(error)
  │
  ├─ 7. Post-Hook (PostToolUse hook execution)
  │     ├── runPostToolUseHooks() — parallel execution
  │     ├── MCP tools: updatedMCPToolOutput possible
  │     ├── PostToolUse timing summary shown when exceeding 500ms
  │     └── On error: runPostToolUseFailureHooks()
  │
  └─ 8. Result Format
        ├── mapToolResultToToolResultBlockParam()
        ├── processToolResultBlock() / processPreMappedToolResultBlock()
        ├── Save to disk + preview when exceeding maxResultSizeChars
        ├── Add acceptFeedback (user feedback)
        ├── Add contentBlocks (images, etc.)
        └── Apply contextModifier
```

### 4.2 callInput vs processedInput Duality

```typescript
// Initial state
let callInput = parsedInput.data           // Model's original input
let processedInput = parsedInput.data      // Input seen by hooks/permissions

// When backfillObservableInput exists:
const backfilledClone = { ...processedInput }
tool.backfillObservableInput!(backfilledClone)
processedInput = backfilledClone    // Hooks see derived fields
// callInput remains original      // call() receives original

// When hooks/permissions return updatedInput:
if (processedInput !== backfilledClone) {
  // Hook provided new input → update callInput
  callInput = processedInput
}

// File path special handling:
// If backfill expanded file_path but hook returns the same expanded path
// → restore original path (VCR hash stability)
```

**Design intent**: Preserve prompt cache (byte-level match) while allowing hooks/permission systems to see derived fields.

### 4.3 backfillObservableInput Mechanism

```
API input (immutable) ──┬──> [call()] tool execution
                        │
                        └──> [clone] ──> backfillObservableInput(clone) ──> hooks/SDK/transcript
                                         │
                                         ├── File tools: file_path expansion (~/ → /home/...)
                                         ├── SendMessageTool: derived field addition
                                         └── ...
```

---

## 5. Streaming Tool Executor

### 5.1 TrackedTool State Machine

```
queued ──> executing ──> completed ──> yielded
  │           │
  │           └── (abort) ──> completed (synthetic error)
  │
  └── (abort before start) ──> completed (synthetic error)
```

```typescript
type ToolStatus = 'queued' | 'executing' | 'completed' | 'yielded'

type TrackedTool = {
  id: string
  block: ToolUseBlock
  assistantMessage: AssistantMessage
  status: ToolStatus
  isConcurrencySafe: boolean       // inputSchema.safeParse → tool.isConcurrencySafe()
  promise?: Promise<void>
  results?: Message[]
  pendingProgress: Message[]       // Progress messages yielded immediately
  contextModifiers?: Array<(context: ToolUseContext) => ToolUseContext>
}
```

### 5.2 canExecuteTool() Concurrency Logic

```typescript
private canExecuteTool(isConcurrencySafe: boolean): boolean {
  const executingTools = this.tools.filter(t => t.status === 'executing')

  return (
    executingTools.length === 0 ||                    // Nothing currently executing
    (isConcurrencySafe &&                             // New tool is concurrency-safe
     executingTools.every(t => t.isConcurrencySafe))  // All existing tools are also concurrency-safe
  )
}
```

**Concurrency rules**:
- Only concurrency-safe tools can execute in parallel with each other
- Non-safe tools require exclusive access (solo execution)
- When a non-safe tool is in the queue, tools behind it do not start

### 5.3 Sibling Tool Abort (On Bash Error)

```typescript
// Only Bash errors cancel siblings (other tools are independent)
if (tool.block.name === BASH_TOOL_NAME && isErrorResult) {
  this.hasErrored = true
  this.erroredToolDescription = this.getToolDescription(tool)
  this.siblingAbortController.abort('sibling_error')
}
```

**Design rationale**: Bash commands commonly have implicit dependency chains (mkdir failure → subsequent commands are meaningless). Read/WebFetch etc. are independent, so one failure does not cancel others.

```
siblingAbortController (child controller)
  ├── toolAbortController[0] ── Bash (error occurred!)
  ├── toolAbortController[1] ── Read (receives abort signal)
  └── toolAbortController[2] ── Grep (receives abort signal)

Parent: toolUseContext.abortController is unaffected (turn does not end)
```

### 5.4 Result Order Guarantee

```typescript
*getCompletedResults(): Generator<MessageUpdate, void> {
  for (const tool of this.tools) {   // Iterate in order of addition
    // Progress messages are always yielded immediately
    while (tool.pendingProgress.length > 0) {
      yield { message: tool.pendingProgress.shift()! }
    }

    if (tool.status === 'yielded') continue

    if (tool.status === 'completed' && tool.results) {
      tool.status = 'yielded'
      for (const message of tool.results) {
        yield { message }
      }
    } else if (tool.status === 'executing' && !tool.isConcurrencySafe) {
      break   // Wait if a non-safe tool is executing
    }
  }
}
```

**Key point**: Progress messages are yielded immediately, but final results maintain the order in which tools were added.

### 5.5 Immediate Progress Message Yield Mechanism

```typescript
// Inside tool execution:
if (update.message.type === 'progress') {
  tool.pendingProgress.push(update.message)
  // Wake up waiting getRemainingResults() via Promise resolve
  if (this.progressAvailableResolve) {
    this.progressAvailableResolve()
    this.progressAvailableResolve = undefined
  }
}

// In getRemainingResults():
await Promise.race([
  ...executingPromises,     // Wait for tool completion
  progressPromise,          // Or wait for progress message
])
```

---

## 6. Command System

### 6.1 Command Type

```typescript
// SettingSource: settings file origin ('userSettings' | 'projectSettings' | 'localSettings' | 'flagSettings' | 'policySettings')
type Command = {
  // Common fields
  name: string
  description: string
  aliases?: string[]
  // source is a union of SettingSource (file-based) + built-in/extension sources
  source: SettingSource | 'builtin' | 'mcp' | 'plugin' | 'bundled'
  // loadedFrom: loading path (for debugging)
  loadedFrom?: 'skills' | 'commands_DEPRECATED' | 'bundled' | 'plugin' | 'mcp'
  availability?: ('claude-ai' | 'console')[]    // Authentication requirements
  disableModelInvocation?: boolean               // Model cannot invoke this

  // Type-based branching
  type: 'prompt' | 'local' | 'local-jsx'

  // prompt type: generates text passed to the model
  getPromptForCommand?(args: string, context): Promise<string>
  contentLength: number
  progressMessage: string

  // prompt type only: fork mode context
  // context: 'fork' → allows execution in subagent (fork) context too
  context?: 'fork'

  // local type: executes locally and returns text result
  // local-jsx type: renders Ink UI (React JSX)
}
```

### 6.2 Command Registration and Filtering

```
Command source hierarchy:
  ├── bundledSkills (getBundledSkills)     // Bundled built-in skills
  ├── builtinPluginSkills                  // Enabled built-in plugins
  ├── skillDirCommands (getSkillDirCommands) // ~/.claude/skills/ directory
  ├── workflowCommands                      // WORKFLOW_SCRIPTS feature gate
  ├── pluginCommands (getPluginCommands)    // Installed plugins
  ├── pluginSkills (getPluginSkills)        // Plugin skills
  └── COMMANDS() (memoized)                 // Built-in commands (~80)
```

**Loading pipeline**:

```typescript
// memoize(cwd) — memoized by cwd due to disk I/O cost
async function getCommands(cwd: string): Promise<Command[]> {
  const allCommands = await loadAllCommands(cwd)   // Memoized
  const dynamicSkills = getDynamicSkills()          // Skills discovered during file operations

  return allCommands
    .filter(meetsAvailabilityRequirement)  // Filter by authentication state
    .filter(isCommandEnabled)              // isEnabled() check
    + uniqueDynamicSkills                  // Insert after deduplication
}
```

### 6.3 Remote-safe and Bridge-safe Command Sets

```typescript
// REMOTE_SAFE_COMMANDS: local commands usable in --remote mode
// Only affect local TUI state, no filesystem/git/IDE dependencies
REMOTE_SAFE_COMMANDS = Set([
  session, exit, clear, help, theme, color, vim,
  cost, usage, copy, btw, feedback, plan,
  keybindings, statusline, stickers, mobile,
])

// BRIDGE_SAFE_COMMANDS: executable when received via Remote Control bridge
// Only 'local' type is gated (prompt is always allowed, local-jsx is always blocked)
BRIDGE_SAFE_COMMANDS = Set([
  compact, clear, cost, summary, releaseNotes, files,
])

function isBridgeSafeCommand(cmd: Command): boolean {
  if (cmd.type === 'local-jsx') return false   // Ink UI is always blocked
  if (cmd.type === 'prompt') return true        // Text expansion is always allowed
  return BRIDGE_SAFE_COMMANDS.has(cmd)          // local is allow-listed only
}
```

### 6.4 Skill Loading Hierarchy

```typescript
// Model-invocable commands shown by SkillTool:
getSkillToolCommands(cwd):
  allCommands.filter(
    cmd.type === 'prompt' &&
    !cmd.disableModelInvocation &&
    cmd.source !== 'builtin' &&
    (cmd.loadedFrom ∈ {'bundled', 'skills', 'commands_DEPRECATED'} ||
     cmd.hasUserSpecifiedDescription ||
     cmd.whenToUse)
  )

// Slash command-only skills:
getSlashCommandToolSkills(cwd):
  allCommands.filter(
    cmd.type === 'prompt' &&
    cmd.source !== 'builtin' &&
    (cmd.hasUserSpecifiedDescription || cmd.whenToUse) &&
    cmd.loadedFrom ∈ {'skills', 'plugin', 'bundled'} ||
    cmd.disableModelInvocation
  )
```

---

## 7. Retry Logic (withRetry.ts)

### 7.1 AsyncGenerator Pattern

`withRetry` is implemented as an AsyncGenerator that yields intermediate state messages during retries.

```typescript
async function* withRetry<T>(
  getClient: () => Promise<Anthropic>,
  operation: (client: Anthropic, attempt: number, context: RetryContext) => Promise<T>,
  options: RetryOptions,
): AsyncGenerator<SystemAPIErrorMessage, T> {
  // yield: state messages during retry wait (api_error type)
  // return: successful result T
  // throw: CannotRetryError (non-retryable) or FallbackTriggeredError
}
```

### 7.2 Error Classification and Handling Strategies

```
Error received
  │
  ├─ Fast Mode active (429/529)?
  │   ├── Overage rejection? → permanently disable + continue
  │   ├── retry-after < 20s? → short wait + continue (cache preservation)
  │   └── retry-after ≥ 20s? → enter cooldown (switch to standard speed) + continue
  │
  ├─ Fast Mode disable error?
  │   └── Permanently disable + continue
  │
  ├─ 529 (Overloaded)?
  │   ├── Non-foreground query? → immediate CannotRetryError (amplification prevention)
  │   ├── consecutive529Errors >= 3 + fallbackModel?
  │   │   └── throw FallbackTriggeredError
  │   └── Normal retry proceeds
  │
  ├─ 401 (Unauthorized)?
  │   ├── Attempt OAuth token refresh
  │   ├── Reset API key cache
  │   └── Retry with new client
  │
  ├─ 403 (Forbidden)?
  │   ├── "OAuth token revoked" → token refresh
  │   ├── Bedrock auth → reset AWS credential cache
  │   └── CCR mode → retry as transient error
  │
  ├─ 400 + context overflow?
  │   ├── Calculate available context
  │   ├── retryContext.maxTokensOverride = adjustedMaxTokens
  │   └── continue
  │
  ├─ ECONNRESET/EPIPE (stale connection)?
  │   ├── Disable keep-alive
  │   └── Retry with new client
  │
  ├─ Vertex auth error?
  │   └── Reset GCP credential cache + retry
  │
  └─ Other
      ├── shouldRetry(error) → retry
      └── !shouldRetry → throw CannotRetryError
```

### 7.3 Persistent Retry (Unattended Sessions)

```typescript
// Enabled via CLAUDE_CODE_UNATTENDED_RETRY environment variable
// Infinite retry on 429/529 + periodic heartbeat

const PERSISTENT_MAX_BACKOFF_MS = 5 * 60 * 1000      // Max 5 min backoff
const PERSISTENT_RESET_CAP_MS = 6 * 60 * 60 * 1000   // Max 6 hour wait
const HEARTBEAT_INTERVAL_MS = 30_000                   // Every 30 seconds yield

// 429 special handling:
// Check reset timestamp from anthropic-ratelimit-unified-reset header
// Wait until reset time (avoid pointless 5-min polling)

// Heartbeat:
// Split long waits into 30-second chunks
// Yield SystemAPIErrorMessage at each interval → host doesn't consider it idle
while (remaining > 0) {
  yield createSystemAPIErrorMessage(error, remaining, attempt, maxRetries)
  await sleep(Math.min(remaining, HEARTBEAT_INTERVAL_MS))
  remaining -= chunk
}
// Pin attempt to maxRetries → for loop never terminates
```

### 7.4 Retry Delay Calculation

```typescript
function getRetryDelay(attempt, retryAfterHeader?, maxDelayMs = 32000): number {
  // Use retry-after header value if present
  if (retryAfterHeader) {
    return parseInt(retryAfterHeader) * 1000
  }

  // Exponential backoff + jitter
  const baseDelay = Math.min(
    BASE_DELAY_MS * Math.pow(2, attempt - 1),   // 500ms, 1s, 2s, 4s, 8s, 16s, 32s
    maxDelayMs,                                   // Default 32s cap
  )
  const jitter = Math.random() * 0.25 * baseDelay  // 0-25% jitter
  return baseDelay + jitter
}
```

### 7.5 Foreground 529 Retry Sources

```typescript
// Only queries where the user is waiting for results retry on 529
const FOREGROUND_529_RETRY_SOURCES = new Set([
  'repl_main_thread',
  'repl_main_thread:outputStyle:custom',
  'repl_main_thread:outputStyle:Explanatory',
  'repl_main_thread:outputStyle:Learning',
  'sdk',
  'agent:custom', 'agent:default', 'agent:builtin',
  'compact',
  'hook_agent', 'hook_prompt',
  'verification_agent',
  'side_question',
  'auto_mode',                // Security classifier
  'bash_classifier',          // ant-only
])
// Summaries, titles, suggestions, classifiers, etc. → immediate failure (amplification prevention)
```

---

## 8. Cost Tracking

### 8.1 Per-Model Pricing Tiers

```typescript
type ModelCosts = {
  inputTokens: number              // $ per Mtok
  outputTokens: number             // $ per Mtok
  promptCacheWriteTokens: number   // ~125% of input (25% premium)
  promptCacheReadTokens: number    // ~10% of input (90% discount)
  webSearchRequests: number        // $ per request
}

// Key pricing tiers:
COST_TIER_3_15   = { input: $3,  output: $15,  cacheWrite: $3.75,  cacheRead: $0.30 }  // Sonnet
COST_TIER_15_75  = { input: $15, output: $75,  cacheWrite: $18.75, cacheRead: $1.50 }  // Opus 4/4.1
COST_TIER_5_25   = { input: $5,  output: $25,  cacheWrite: $6.25,  cacheRead: $0.50 }  // Opus 4.5
COST_TIER_30_150 = { input: $30, output: $150, cacheWrite: $37.5,  cacheRead: $3.00 }  // Opus 4.6 fast
COST_HAIKU_35    = { input: $0.8, output: $4,  cacheWrite: $1.00,  cacheRead: $0.08 }  // Haiku 3.5
```

### 8.2 Cost Calculation Formula

```typescript
function calculateUSDCost(model: string, usage: Usage): number {
  const costs = getCostsForModel(model)

  return (
    (usage.input_tokens * costs.inputTokens / 1_000_000) +
    (usage.output_tokens * costs.outputTokens / 1_000_000) +
    ((usage.cache_creation_input_tokens ?? 0) * costs.promptCacheWriteTokens / 1_000_000) +
    ((usage.cache_read_input_tokens ?? 0) * costs.promptCacheReadTokens / 1_000_000) +
    ((usage.server_tool_use?.web_search_requests ?? 0) * costs.webSearchRequests)
  )
}
```

### 8.3 Session Persistence and Restoration

```typescript
type StoredCostState = {
  totalCostUSD: number
  totalAPIDuration: number
  totalAPIDurationWithoutRetries: number
  totalToolDuration: number
  totalLinesAdded: number
  totalLinesRemoved: number
  lastDuration: number | undefined
  modelUsage: { [modelName: string]: ModelUsage } | undefined
}

// Save: saveCurrentSessionCosts()
// → stored in getCurrentProjectConfig() (lastCost, lastAPIDuration, ...)

// Restore: restoreCostStateForSession(sessionId)
// → only restores when sessionId matches lastSessionId
// → setCostStateForRestore(data)
```

### 8.4 Per-Model Usage Tracking

```typescript
type ModelUsage = {
  inputTokens: number
  outputTokens: number
  cacheReadInputTokens: number
  cacheCreationInputTokens: number
  webSearchRequests: number
  costUSD: number
  contextWindow: number          // Model's context window size
  maxOutputTokens: number        // Model's maximum output tokens
}

function addToTotalSessionCost(cost: number, usage: Usage, model: string): number {
  // 1. Accumulate per-model usage
  const modelUsage = addToTotalModelUsage(cost, usage, model)

  // 2. Add to global state
  addToTotalCostState(cost, modelUsage, model)

  // 3. Update OTel counters
  getCostCounter()?.add(cost, { model })
  getTokenCounter()?.add(usage.input_tokens, { model, type: 'input' })
  getTokenCounter()?.add(usage.output_tokens, { model, type: 'output' })
  getTokenCounter()?.add(cacheRead, { model, type: 'cacheRead' })
  getTokenCounter()?.add(cacheCreation, { model, type: 'cacheCreation' })

  // 4. Recursively process Advisor usage
  for (const advisorUsage of getAdvisorUsage(usage)) {
    totalCost += addToTotalSessionCost(
      calculateUSDCost(advisorUsage.model, advisorUsage),
      advisorUsage,
      advisorUsage.model,
    )
  }

  return totalCost
}
```

### 8.5 Token Tracking Flow in QueryEngine

```
API streaming start
  │
  ├── message_start event
  │   └── currentMessageUsage = updateUsage(EMPTY, event.message.usage)
  │
  ├── message_delta event (repeated)
  │   └── currentMessageUsage = updateUsage(current, event.usage)
  │
  └── message_stop event
      └── totalUsage = accumulateUsage(totalUsage, currentMessageUsage)

// accumulateUsage: sums all fields
// updateUsage: replaces with latest values (cumulative values from delta)

// Cost calculation in claude.ts:
// On message_delta receipt → addToTotalSessionCost(cost, usage, model)
// → per-model accumulation + OTel counters + Advisor recursion
```

---

## Appendix: Core Design Principles Summary

1. **Fail-closed defaults**: `isConcurrencySafe=false`, `isReadOnly=false` — assume unsafe and require explicit opt-in
2. **Prompt cache preservation**: `backfillObservableInput` applies only to clones; original API input is never modified
3. **Watermark-based error scoping**: Snapshot error log at turn start to prevent unrelated errors from appearing in results
4. **AsyncGenerator pattern**: Yield intermediate state messages (retries, progress, compaction) while returning final results
5. **Feature-gated dead code elimination**: `require()` inside `feature('X')` conditionals to remove from external builds
6. **Sibling abort restricted to Bash**: Only Bash cancels other parallel tools; Read/Grep etc. do not affect each other
7. **Amplification prevention**: Non-foreground queries do not retry on 529 to prevent cascading overload

---

## Implementation Caveats

### C1. contextModifier Atomicity Not Guaranteed
`ToolResult.contextModifier` is applied in a sequential loop in `StreamingToolExecutor` (`:391-395`). When multiple tools have modifiers, if another tool reads `getAppState()` during the loop, it may see a partially-applied state. **Modifier application is not atomic.**

### C2. API Registration of shouldDefer Tools
Tools with `shouldDefer: true` only have stubs sent in the initial API tool list. When `ToolSearchTool` matches them, the full schema is loaded. This mechanism depends on the LazySchema pattern, and the `inputSchema` must be available at invocation time.

### C3. Bash Error Cascade — Bash Only
The logic to cancel sibling tools on error during tool execution is **hardcoded to the Bash tool only** (`BASH_TOOL_NAME` check). Adding new shell tools does not automatically inherit this cascade behavior.

### C4. Zod v4 Considerations
This project uses `zod/v4`. Key differences from v3: uses `lazySchema()` helper instead of `z.lazy()`, changed `.safeParse()` error format, different `.passthrough()` behavior. Referencing v3 documentation may cause subtle runtime errors.
