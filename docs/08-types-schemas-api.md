# Part 8: Type System, Schemas & API Contracts

> Reverse engineering design document for the Claude Code CLI — Complete type system, schema, and API contract reference
> Source paths: `src/Tool.ts`, `src/types/`, `src/schemas/`, `src/state/`, `src/services/mcp/types.ts`, `src/tasks/types.ts`, `src/constants/`

---

## Table of Contents

1. [Core Types](#1-core-types)
2. [ID Types (Branded)](#2-id-types-branded)
3. [AppState Shape](#3-appstate-shape)
4. [Store\<T\>](#4-storet)
5. [Hook Schemas (Zod)](#5-hook-schemas-zod)
6. [MCP Types](#6-mcp-types)
7. [Task Types](#7-task-types)
8. [Permission Types](#8-permission-types)
9. [Environment Variables](#9-environment-variables)
10. [Feature Flags](#10-feature-flags)
11. [Analytics Event Names](#11-analytics-event-names)
12. [Constants](#12-constants)

---

## 1. Core Types

### 1.1 ValidationResult

Tool input validation result. Success/failure discriminated union.

```typescript
/**
 * Tool input validation result.
 * result: true  -> valid input
 * result: false -> includes error message + error code
 */
export type ValidationResult =
  | { result: true }
  | {
      result: false
      /** Error message displayed to user */
      message: string
      /** HTTP-style error code (2 = hook blocked, etc.) */
      errorCode: number
    }
```

### 1.2 Tool\<Input, Output, Progress\>

The core interface of the system. A complete definition with 60+ fields implemented by all tools (Bash, Edit, Read, Agent, MCP, etc.).

```typescript
import type { z } from 'zod/v4'
import type { ToolResultBlockParam, ToolUseBlockParam } from '@anthropic-ai/sdk/resources/index.mjs'

/** JSON Schema compatible tool input schema */
export type ToolInputJSONSchema = {
  [x: string]: unknown
  type: 'object'
  properties?: { [x: string]: unknown }
}

/** Shorthand for z.ZodType<{ [key: string]: unknown }> */
export type AnyObject = z.ZodType<{ [key: string]: unknown }>

/**
 * Claude Code CLI tool interface.
 * @template Input  - Zod input schema (z.ZodObject, etc.)
 * @template Output - Data type returned by call()
 * @template P      - Progress event data type (BashProgress, AgentToolProgress, etc.)
 */
export type Tool<
  Input extends AnyObject = AnyObject,
  Output = unknown,
  P extends ToolProgressData = ToolProgressData,
> = {
  // ===== Identification =====
  /** Unique name of the tool (e.g., 'Bash', 'Edit', 'Read') */
  readonly name: string
  /** Aliases for backward compatibility (e.g., 'Task' -> 'Agent') */
  aliases?: string[]
  /** Hints for ToolSearch keyword matching (3-10 words). Recommended to use words not in tool name. */
  searchHint?: string

  // ===== Schema =====
  /** Zod input schema. Converted to JSON Schema by the API. */
  readonly inputSchema: Input
  /** For MCP tools: directly provide JSON Schema without Zod conversion */
  readonly inputJSONSchema?: ToolInputJSONSchema
  /** Output schema (optional). Undefined for TungstenTool. */
  outputSchema?: z.ZodType<unknown>

  // ===== Core Execution =====
  /**
   * Execute the tool and return results.
   * @param args         - Parsed input inferred from inputSchema
   * @param context      - ToolUseContext (30+ fields, see below)
   * @param canUseTool   - Callback to check if tool can be used
   * @param parentMessage - The assistant message containing this tool call
   * @param onProgress   - Progress event callback (optional)
   */
  call(
    args: z.infer<Input>,
    context: ToolUseContext,
    canUseTool: CanUseToolFn,
    parentMessage: AssistantMessage,
    onProgress?: ToolCallProgress<P>,
  ): Promise<ToolResult<Output>>

  // ===== Dynamic Description/Prompt =====
  /** Generate dynamic description based on current input */
  description(
    input: z.infer<Input>,
    options: {
      isNonInteractiveSession: boolean
      toolPermissionContext: ToolPermissionContext
      tools: Tools
    },
  ): Promise<string>
  /** Tool prompt text to be included in the system prompt */
  prompt(options: {
    getToolPermissionContext: () => Promise<ToolPermissionContext>
    tools: Tools
    agents: AgentDefinition[]
    allowedAgentTypes?: string[]
  }): Promise<string>

  // ===== Validation & Permission =====
  /** Input validation (optional). Called before checkPermissions. */
  validateInput?(
    input: z.infer<Input>,
    context: ToolUseContext,
  ): Promise<ValidationResult>
  /** Permission check. Called after validateInput passes. */
  checkPermissions(
    input: z.infer<Input>,
    context: ToolUseContext,
  ): Promise<PermissionResult>
  /** Prepare matcher for hook `if` conditions (e.g., "Bash(git *)") */
  preparePermissionMatcher?(
    input: z.infer<Input>,
  ): Promise<(pattern: string) => boolean>

  // ===== Tool Properties =====
  /** Whether the tool is enabled. Default: true */
  isEnabled(): boolean
  /** Whether concurrent execution is safe. Default: false (not safe) */
  isConcurrencySafe(input: z.infer<Input>): boolean
  /** Whether the tool is read-only. Default: false (writable) */
  isReadOnly(input: z.infer<Input>): boolean
  /** Whether this is an irreversible destructive operation. Default: false */
  isDestructive?(input: z.infer<Input>): boolean
  /** Compare whether two inputs are equivalent (used in speculation, etc.) */
  inputsEquivalent?(a: z.infer<Input>, b: z.infer<Input>): boolean
  /** Extract file path the tool operates on (optional) */
  getPath?(input: z.infer<Input>): string

  // ===== Interrupt Behavior =====
  /**
   * Behavior of a running tool when the user sends a new message.
   * - 'cancel': Abort the tool and discard results
   * - 'block':  Continue execution; new message waits
   * Default: 'block'
   */
  interruptBehavior?(): 'cancel' | 'block'

  // ===== Search/Read Classification =====
  /** Search/read operation classification for UI collapsed display */
  isSearchOrReadCommand?(input: z.infer<Input>): {
    isSearch: boolean
    isRead: boolean
    isList?: boolean
  }
  /** Whether it accesses the external world (web search, etc.) */
  isOpenWorld?(input: z.infer<Input>): boolean
  /** Whether user interaction is required */
  requiresUserInteraction?(): boolean

  // ===== MCP/LSP/Deferred =====
  /** Whether this is an MCP tool */
  isMcp?: boolean
  /** Whether this is an LSP tool */
  isLsp?: boolean
  /** Whether this is a deferred-load tool sent with defer_loading: true */
  readonly shouldDefer?: boolean
  /** Whether this tool is always loaded even without ToolSearch */
  readonly alwaysLoad?: boolean
  /** Original server/tool name info for MCP tools */
  mcpInfo?: { serverName: string; toolName: string }
  /** Enable strict mode (requires tengu_tool_pear feature) */
  readonly strict?: boolean

  // ===== Result Size Limit =====
  /**
   * Maximum character count for tool results. Exceeding saves to disk and provides preview.
   * The Read tool uses Infinity (to prevent circular loops).
   */
  maxResultSizeChars: number

  // ===== Input Transformation =====
  /**
   * Add legacy/derived fields to a copy of tool input before observers see it.
   * Original API input is not modified (preserves prompt cache).
   * Idempotency required.
   */
  backfillObservableInput?(input: Record<string, unknown>): void

  // ===== Security Classification =====
  /** Compact representation for auto-mode security classifier. Returns '' to skip classification. */
  toAutoClassifierInput(input: z.infer<Input>): unknown

  // ===== Result Transformation =====
  /** Transform tool result into API tool_result block */
  mapToolResultToToolResultBlockParam(
    content: Output,
    toolUseID: string,
  ): ToolResultBlockParam

  // ===== UI Rendering (React) =====
  /** Tool name displayed to user */
  userFacingName(input: Partial<z.infer<Input>> | undefined): string
  /** Tool name background color (theme key) */
  userFacingNameBackgroundColor?(
    input: Partial<z.infer<Input>> | undefined,
  ): keyof Theme | undefined
  /** Whether this is a transparent wrapper (REPL, etc.: no own UI) */
  isTransparentWrapper?(): boolean
  /** Short summary string for compact view */
  getToolUseSummary?(input: Partial<z.infer<Input>> | undefined): string | null
  /** Activity description to display on spinner (e.g., "Reading src/foo.ts") */
  getActivityDescription?(
    input: Partial<z.infer<Input>> | undefined,
  ): string | null
  /** Whether the result is truncated in non-verbose mode */
  isResultTruncated?(output: Output): boolean
  /** Extract rendered text for text search indexing */
  extractSearchText?(out: Output): string

  /** Render tool use message (partial input possible during streaming) */
  renderToolUseMessage(
    input: Partial<z.infer<Input>>,
    options: { theme: ThemeName; verbose: boolean; commands?: Command[] },
  ): React.ReactNode
  /** Render tags after tool use message (timeout, model, etc.) */
  renderToolUseTag?(input: Partial<z.infer<Input>>): React.ReactNode
  /** Render tool result message (optional) */
  renderToolResultMessage?(
    content: Output,
    progressMessagesForMessage: ProgressMessage<P>[],
    options: {
      style?: 'condensed'
      theme: ThemeName
      tools: Tools
      verbose: boolean
      isTranscriptMode?: boolean
      isBriefOnly?: boolean
      input?: unknown
    },
  ): React.ReactNode
  /** Render progress state UI (optional) */
  renderToolUseProgressMessage?(
    progressMessagesForMessage: ProgressMessage<P>[],
    options: {
      tools: Tools
      verbose: boolean
      terminalSize?: { columns: number; rows: number }
      inProgressToolCallCount?: number
      isTranscriptMode?: boolean
    },
  ): React.ReactNode
  /** Render pending message (optional) */
  renderToolUseQueuedMessage?(): React.ReactNode
  /** Render rejection message (optional, falls back to FallbackToolUseRejectedMessage if undefined) */
  renderToolUseRejectedMessage?(
    input: z.infer<Input>,
    options: {
      columns: number
      messages: Message[]
      style?: 'condensed'
      theme: ThemeName
      tools: Tools
      verbose: boolean
      progressMessagesForMessage: ProgressMessage<P>[]
      isTranscriptMode?: boolean
    },
  ): React.ReactNode
  /** Render error message (optional, falls back to FallbackToolUseErrorMessage if undefined) */
  renderToolUseErrorMessage?(
    result: ToolResultBlockParam['content'],
    options: {
      progressMessagesForMessage: ProgressMessage<P>[]
      tools: Tools
      verbose: boolean
      isTranscriptMode?: boolean
    },
  ): React.ReactNode
  /** Render grouped parallel tools (non-verbose mode only) */
  renderGroupedToolUse?(
    toolUses: Array<{
      param: ToolUseBlockParam
      isResolved: boolean
      isError: boolean
      isInProgress: boolean
      progressMessages: ProgressMessage<P>[]
      result?: { param: ToolResultBlockParam; output: unknown }
    }>,
    options: { shouldAnimate: boolean; tools: Tools },
  ): React.ReactNode | null
}

/** Tool collection. Use this type instead of Tool[] for easier tracking */
export type Tools = readonly Tool[]
```

### 1.3 ToolDef & buildTool

`buildTool()` is a factory function that fills in defaults to create a complete `Tool`.

```typescript
/**
 * Method keys for which buildTool provides defaults.
 * These keys are optional in ToolDef.
 */
type DefaultableToolKeys =
  | 'isEnabled'        // Default: () => true
  | 'isConcurrencySafe' // Default: () => false (not safe)
  | 'isReadOnly'       // Default: () => false (writable)
  | 'isDestructive'    // Default: () => false
  | 'checkPermissions' // Default: allow + passthrough
  | 'toAutoClassifierInput' // Default: '' (skip classification)
  | 'userFacingName'   // Default: return name

export type ToolDef<Input, Output, P> =
  Omit<Tool<Input, Output, P>, DefaultableToolKeys> &
  Partial<Pick<Tool<Input, Output, P>, DefaultableToolKeys>>

/**
 * Fill safe defaults into tool definition and return a complete Tool object.
 * All tool exports should go through this function so defaults are managed in one place.
 */
export function buildTool<D extends AnyToolDef>(def: D): BuiltTool<D>
```

### 1.4 ToolResult\<T\>

```typescript
/**
 * Return value of a tool call.
 * @template T - Result data type
 */
export type ToolResult<T> = {
  /** Tool execution result data */
  data: T
  /** New messages to add to conversation (optional) */
  newMessages?: (UserMessage | AssistantMessage | AttachmentMessage | SystemMessage)[]
  /** Tool context modifier (only applied for non-concurrency-safe tools) */
  contextModifier?: (context: ToolUseContext) => ToolUseContext
  /** MCP protocol metadata (for SDK consumer delivery) */
  mcpMeta?: {
    _meta?: Record<string, unknown>
    structuredContent?: Record<string, unknown>
  }
}
```

### 1.5 ToolUseContext (30+ Fields)

Complete context object passed during tool calls.

```typescript
export type ToolUseContext = {
  // ===== Options =====
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
    refreshTools?: () => Tools
  }

  // ===== Execution Control =====
  abortController: AbortController
  readFileState: FileStateCache

  // ===== State Access =====
  getAppState(): AppState
  setAppState(f: (prev: AppState) => AppState): void
  /** Always-shared setAppState for session-scoped infrastructure. Reaches root store even from subagents. */
  setAppStateForTasks?: (f: (prev: AppState) => AppState) => void

  // ===== MCP Integration =====
  /** URL elicitation handler on MCP tool call error (-32042) */
  handleElicitation?: (
    serverName: string,
    params: ElicitRequestURLParams,
    signal: AbortSignal,
  ) => Promise<ElicitResult>

  // ===== UI Callbacks (REPL only) =====
  setToolJSX?: SetToolJSXFn
  addNotification?: (notif: Notification) => void
  appendSystemMessage?: (msg: Exclude<SystemMessage, SystemLocalCommandMessage>) => void
  sendOSNotification?: (opts: { message: string; notificationType: string }) => void
  setStreamMode?: (mode: SpinnerMode) => void
  onCompactProgress?: (event: CompactProgressEvent) => void
  setSDKStatus?: (status: SDKStatus) => void
  openMessageSelector?: () => void

  // ===== Memory/Attachments =====
  nestedMemoryAttachmentTriggers?: Set<string>
  loadedNestedMemoryPaths?: Set<string>
  dynamicSkillDirTriggers?: Set<string>
  discoveredSkillNames?: Set<string>

  // ===== State Tracking =====
  userModified?: boolean
  setInProgressToolUseIDs: (f: (prev: Set<string>) => Set<string>) => void
  setHasInterruptibleToolInProgress?: (v: boolean) => void
  setResponseLength: (f: (prev: number) => number) => void
  pushApiMetricsEntry?: (ttftMs: number) => void

  // ===== File/Attribution =====
  updateFileHistoryState: (updater: (prev: FileHistoryState) => FileHistoryState) => void
  updateAttributionState: (updater: (prev: AttributionState) => AttributionState) => void

  // ===== Session/Agent Identification =====
  setConversationId?: (id: UUID) => void
  agentId?: AgentId     // Subagent only; main thread uses getSessionId()
  agentType?: string    // Subagent type name

  // ===== Tool Execution Context =====
  requireCanUseTool?: boolean  // For speculation: always call canUseTool
  messages: Message[]
  fileReadingLimits?: { maxTokens?: number; maxSizeBytes?: number }
  globLimits?: { maxResults?: number }
  toolDecisions?: Map<string, {
    source: string
    decision: 'accept' | 'reject'
    timestamp: number
  }>
  queryTracking?: QueryChainTracking
  toolUseId?: string
  criticalSystemReminder_EXPERIMENTAL?: string
  preserveToolUseResults?: boolean

  // ===== Permission Tracking =====
  localDenialTracking?: DenialTrackingState
  contentReplacementState?: ContentReplacementState

  // ===== System Prompt =====
  renderedSystemPrompt?: SystemPrompt

  // ===== Prompt Request (REPL only) =====
  requestPrompt?: (
    sourceName: string,
    toolInputSummary?: string | null,
  ) => (request: PromptRequest) => Promise<PromptResponse>
}
```

### 1.6 ToolPermissionContext

Immutable permission context with DeepImmutable wrapper applied.

```typescript
/**
 * Immutable context required for tool permission checks.
 * All fields are readonly via DeepImmutable<T>.
 */
export type ToolPermissionContext = DeepImmutable<{
  mode: PermissionMode
  additionalWorkingDirectories: Map<string, AdditionalWorkingDirectory>
  alwaysAllowRules: ToolPermissionRulesBySource
  alwaysDenyRules: ToolPermissionRulesBySource
  alwaysAskRules: ToolPermissionRulesBySource
  isBypassPermissionsModeAvailable: boolean
  isAutoModeAvailable?: boolean
  strippedDangerousRules?: ToolPermissionRulesBySource
  /** When true, automatically deny permission prompts (background agents, etc.) */
  shouldAvoidPermissionPrompts?: boolean
  /** When true, wait for automated checks (classifiers, hooks) before dialog */
  awaitAutomatedChecksBeforeDialog?: boolean
  /** Permission mode before model entered plan mode (for restoration) */
  prePlanMode?: PermissionMode
}>

/** Create an empty ToolPermissionContext */
export const getEmptyToolPermissionContext: () => ToolPermissionContext
```

### 1.7 Command Type (Discriminated Union)

```typescript
/**
 * Three types of commands.
 * Union discriminated by the type field.
 */
export type Command = CommandBase & (PromptCommand | LocalCommand | LocalJSXCommand)

type CommandBase = {
  availability?: CommandAvailability[]    // 'claude-ai' | 'console'
  description: string
  hasUserSpecifiedDescription?: boolean
  isEnabled?: () => boolean               // Default: true
  isHidden?: boolean                      // Default: false
  name: string
  aliases?: string[]
  isMcp?: boolean
  argumentHint?: string
  whenToUse?: string                      // Usage scenario from skill spec
  version?: string
  disableModelInvocation?: boolean
  userInvocable?: boolean
  loadedFrom?: 'commands_DEPRECATED' | 'skills' | 'plugin' | 'managed' | 'bundled' | 'mcp'
  kind?: 'workflow'
  immediate?: boolean                     // If true, execute immediately without queue wait
  isSensitive?: boolean                   // If true, redact arguments from conversation history
  userFacingName?: () => string           // Default: name
}

/**
 * 'prompt' type: prompt command sent to LLM (skills)
 */
type PromptCommand = {
  type: 'prompt'
  progressMessage: string
  contentLength: number
  argNames?: string[]
  allowedTools?: string[]
  model?: string
  source: SettingSource | 'builtin' | 'mcp' | 'plugin' | 'bundled'
  pluginInfo?: { pluginManifest: PluginManifest; repository: string }
  disableNonInteractive?: boolean
  hooks?: HooksSettings
  skillRoot?: string
  context?: 'inline' | 'fork'   // 'inline'=current conversation, 'fork'=subagent
  agent?: string                 // Agent type for fork
  effort?: EffortValue
  paths?: string[]               // glob patterns: show only after accessing matching files
  getPromptForCommand(args: string, context: ToolUseContext): Promise<ContentBlockParam[]>
}

/**
 * 'local' type: non-JSX command executed locally
 */
type LocalCommand = {
  type: 'local'
  supportsNonInteractive: boolean
  load: () => Promise<LocalCommandModule>
}

/**
 * 'local-jsx' type: interactive command that returns React JSX
 */
type LocalJSXCommand = {
  type: 'local-jsx'
  load: () => Promise<LocalJSXCommandModule>
}
```

### 1.8 ToolProgressData Types

```typescript
/** Tool progress event wrapper */
export type ToolProgress<P extends ToolProgressData> = {
  toolUseID: string
  data: P
}

/** Progress callback function */
export type ToolCallProgress<P extends ToolProgressData = ToolProgressData> = (
  progress: ToolProgress<P>,
) => void

/** Full progress data union */
export type Progress = ToolProgressData | HookProgress

/** CompactProgressEvent - compaction progress tracking */
export type CompactProgressEvent =
  | { type: 'hooks_start'; hookType: 'pre_compact' | 'post_compact' | 'session_start' }
  | { type: 'compact_start' }
  | { type: 'compact_end' }
```

### 1.9 QueryChainTracking

```typescript
/** Query chain tracking (managing chained call depth) */
export type QueryChainTracking = {
  chainId: string
  depth: number
}
```

---

## 2. ID Types (Branded)

TypeScript branded types that prevent mixing up session IDs and agent IDs at compile time.

```typescript
// ===== Session ID =====

/**
 * Claude Code session unique identifier.
 * Created via getSessionId(). Attaches __brand tag to plain string.
 */
export type SessionId = string & { readonly __brand: 'SessionId' }

/** Cast string to SessionId (prefer getSessionId() when possible) */
export function asSessionId(id: string): SessionId

// ===== Agent ID =====

/**
 * Unique identifier for a subagent within a session.
 * Created via createAgentId(). Format: `a` + optional `<label>-` + 16-digit hex.
 * Examples: "a1234567890abcdef", "aexplore-1234567890abcdef"
 */
export type AgentId = string & { readonly __brand: 'AgentId' }

/** Cast string to AgentId */
export function asAgentId(id: string): AgentId

/**
 * Validate whether a string matches AgentId format, then attach brand.
 * Pattern: /^a(?:.+-)?[0-9a-f]{16}$/
 * Returns null on failure.
 */
export function toAgentId(s: string): AgentId | null

// ===== Task ID =====

/**
 * Task ID alphabet: 0-9 + a-z (36 characters).
 * Case-insensitively safe. 36^8 ~= 2.8 trillion combinations.
 */
const TASK_ID_ALPHABET = '0123456789abcdefghijklmnopqrstuvwxyz'

/**
 * Task ID prefix rules (1-character prefix per type + 8 random digits):
 *
 * | TaskType              | Prefix | Example     |
 * |-----------------------|--------|-------------|
 * | local_bash            | b      | b1a2b3c4d5e6f7g8 |
 * | local_agent           | a      | a... |
 * | remote_agent          | r      | r... |
 * | in_process_teammate   | t      | t... |
 * | local_workflow        | w      | w... |
 * | monitor_mcp           | m      | m... |
 * | dream                 | d      | d... |
 * | (unknown type)         | x      | x... |
 */
export function generateTaskId(type: TaskType): string
```

---

## 3. AppState Shape

`AppState` is the single state tree for the entire application. Immutability is enforced at the type level via the `DeepImmutable<>` wrapper, except for `tasks` and others that contain function types.

```typescript
export type AppState = DeepImmutable<{
  // ===== Settings =====
  settings: SettingsJson
  verbose: boolean
  mainLoopModel: ModelSetting              // Model alias, full name, or null
  mainLoopModelForSession: ModelSetting
  statusLineText: string | undefined
  isBriefOnly: boolean

  // ===== UI View State =====
  expandedView: 'none' | 'tasks' | 'teammates'
  selectedIPAgentIndex: number             // In-process teammate selection index
  coordinatorTaskIndex: number             // Coordinator task panel selection (-1=pill, 0=main)
  viewSelectionMode: 'none' | 'selecting-agent' | 'viewing-agent'
  footerSelection: FooterItem | null       // 'tasks'|'tmux'|'bagel'|'teams'|'bridge'|'companion'
  showTeammateMessagePreview?: boolean

  // ===== Permission =====
  toolPermissionContext: ToolPermissionContext
  spinnerTip?: string

  // ===== Session Info =====
  agent: string | undefined                // --agent CLI flag value
  kairosEnabled: boolean                   // Whether assistant mode is fully enabled

  // ===== Remote Session =====
  remoteSessionUrl: string | undefined
  remoteConnectionStatus: 'connecting' | 'connected' | 'reconnecting' | 'disconnected'
  remoteBackgroundTaskCount: number

  // ===== Bridge State (13 fields) =====
  replBridgeEnabled: boolean
  replBridgeExplicit: boolean
  replBridgeOutboundOnly: boolean
  replBridgeConnected: boolean
  replBridgeSessionActive: boolean
  replBridgeReconnecting: boolean
  replBridgeConnectUrl: string | undefined
  replBridgeSessionUrl: string | undefined
  replBridgeEnvironmentId: string | undefined
  replBridgeSessionId: string | undefined
  replBridgeError: string | undefined
  replBridgeInitialName: string | undefined
  showRemoteCallout: boolean
}> & {
  // ===== Area Excluded from DeepImmutable (contains function types) =====

  // Task state map
  tasks: { [taskId: string]: TaskState }
  // Agent name registry (name -> AgentId)
  agentNameRegistry: Map<string, AgentId>
  foregroundedTaskId?: string
  viewingAgentTaskId?: string

  // Companion (buddy) state
  companionReaction?: string
  companionPetAt?: number

  // ===== MCP State =====
  mcp: {
    clients: MCPServerConnection[]
    tools: Tool[]
    commands: Command[]
    resources: Record<string, ServerResource[]>
    pluginReconnectKey: number             // Incremented by /reload-plugins
  }

  // ===== Plugin State =====
  plugins: {
    enabled: LoadedPlugin[]
    disabled: LoadedPlugin[]
    commands: Command[]
    errors: PluginError[]
    installationStatus: {
      marketplaces: Array<{ name: string; status: 'pending'|'installing'|'installed'|'failed'; error?: string }>
      plugins: Array<{ id: string; name: string; status: 'pending'|'installing'|'installed'|'failed'; error?: string }>
    }
    needsRefresh: boolean
  }

  // ===== Agent/File/Todo =====
  agentDefinitions: AgentDefinitionsResult
  fileHistory: FileHistoryState
  attribution: AttributionState
  todos: { [agentId: string]: TodoList }
  remoteAgentTaskSuggestions: { summary: string; task: string }[]

  // ===== Notification/Elicitation =====
  notifications: { current: Notification | null; queue: Notification[] }
  elicitation: { queue: ElicitationRequestEvent[] }

  // ===== Feature Toggles =====
  thinkingEnabled: boolean | undefined
  promptSuggestionEnabled: boolean
  sessionHooks: SessionHooksState

  // ===== Tungsten (tmux) State =====
  tungstenActiveSession?: { sessionName: string; socketName: string; target: string }
  tungstenLastCapturedTime?: number
  tungstenLastCommand?: { command: string; timestamp: number }
  tungstenPanelVisible?: boolean
  tungstenPanelAutoHidden?: boolean

  // ===== WebBrowser (bagel) State =====
  bagelActive?: boolean
  bagelUrl?: string
  bagelPanelVisible?: boolean

  // ===== Computer Use MCP (Chicago) State =====
  computerUseMcpState?: {
    allowedApps?: readonly { bundleId: string; displayName: string; grantedAt: number }[]
    grantFlags?: { clipboardRead: boolean; clipboardWrite: boolean; systemKeyCombos: boolean }
    lastScreenshotDims?: { width: number; height: number; displayWidth: number; displayHeight: number; displayId?: number; originX?: number; originY?: number }
    hiddenDuringTurn?: ReadonlySet<string>
    selectedDisplayId?: number
    displayPinnedByModel?: boolean
    displayResolvedForApps?: string
  }

  // ===== REPL VM Context =====
  replContext?: {
    vmContext: import('vm').Context
    registeredTools: Map<string, { name: string; description: string; schema: Record<string, unknown>; handler: (args: Record<string, unknown>) => Promise<unknown> }>
    console: { log: Function; error: Function; warn: Function; info: Function; debug: Function; getStdout: () => string; getStderr: () => string; clear: () => void }
  }

  // ===== Team/Swarm Context =====
  teamContext?: {
    teamName: string
    teamFilePath: string
    leadAgentId: string
    selfAgentId?: string
    selfAgentName?: string
    isLeader?: boolean
    selfAgentColor?: string
    teammates: { [teammateId: string]: { name: string; agentType?: string; color?: string; tmuxSessionName: string; tmuxPaneId: string; cwd: string; worktreePath?: string; spawnedAt: number } }
  }
  standaloneAgentContext?: { name: string; color?: AgentColorName }

  // ===== Inbox/Permission Requests =====
  inbox: { messages: Array<{ id: string; from: string; text: string; timestamp: string; status: 'pending'|'processing'|'processed'; color?: string; summary?: string }> }
  workerSandboxPermissions: { queue: Array<{ requestId: string; workerId: string; workerName: string; workerColor?: string; host: string; createdAt: number }>; selectedIndex: number }
  pendingWorkerRequest: { toolName: string; toolUseId: string; description: string } | null
  pendingSandboxRequest: { requestId: string; host: string } | null

  // ===== Speculation =====
  promptSuggestion: { text: string | null; promptId: 'user_intent' | 'stated_intent' | null; shownAt: number; acceptedAt: number; generationRequestId: string | null }
  speculation: SpeculationState
  speculationSessionTimeSavedMs: number

  // ===== Miscellaneous =====
  skillImprovement: { suggestion: { skillName: string; updates: { section: string; change: string; reason: string }[] } | null }
  authVersion: number
  initialMessage: { message: UserMessage; clearContext?: boolean; mode?: PermissionMode; allowedPrompts?: AllowedPrompt[] } | null
  pendingPlanVerification?: { plan: string; verificationStarted: boolean; verificationCompleted: boolean }
  denialTracking?: DenialTrackingState
  activeOverlays: ReadonlySet<string>
  fastMode?: boolean
  advisorModel?: string
  effortValue?: EffortValue

  // ===== Ultraplan =====
  ultraplanLaunching?: boolean
  ultraplanSessionUrl?: string
  ultraplanPendingChoice?: { plan: string; sessionId: string; taskId: string }
  ultraplanLaunchPending?: { blurb: string }
  isUltraplanMode?: boolean

  // ===== Bridge Permission Callbacks =====
  replBridgePermissionCallbacks?: BridgePermissionCallbacks
  channelPermissionCallbacks?: ChannelPermissionCallbacks
}
```

### 3.1 SpeculationState

```typescript
export type SpeculationState =
  | { status: 'idle' }
  | {
      status: 'active'
      id: string
      abort: () => void
      startTime: number
      messagesRef: { current: Message[] }
      writtenPathsRef: { current: Set<string> }
      boundary: CompletionBoundary | null
      suggestionLength: number
      toolUseCount: number
      isPipelined: boolean
      contextRef: { current: REPLHookContext }
      pipelinedSuggestion?: {
        text: string
        promptId: 'user_intent' | 'stated_intent'
        generationRequestId: string | null
      } | null
    }

export type CompletionBoundary =
  | { type: 'complete'; completedAt: number; outputTokens: number }
  | { type: 'bash'; command: string; completedAt: number }
  | { type: 'edit'; toolName: string; filePath: string; completedAt: number }
  | { type: 'denied_tool'; toolName: string; detail: string; completedAt: number }
```

---

## 4. Store\<T\>

A minimal state management store similar to Zustand. Prevents unnecessary subscription notifications via `Object.is()` equality check.

```typescript
type Listener = () => void
type OnChange<T> = (args: { newState: T; oldState: T }) => void

/**
 * Minimal reactive store.
 * - getState(): return current snapshot
 * - setState(): change state via updater function. Ignored if Object.is(next, prev).
 * - subscribe(): register listener. Returns unsubscribe function.
 */
export type Store<T> = {
  getState: () => T
  setState: (updater: (prev: T) => T) => void
  subscribe: (listener: Listener) => () => void
}

/**
 * Create a store.
 * @param initialState - Initial state
 * @param onChange     - Callback invoked on state change (optional)
 */
export function createStore<T>(
  initialState: T,
  onChange?: OnChange<T>,
): Store<T>

/** Application-wide global store type */
export type AppStateStore = Store<AppState>
```

---

## 4.5 Settings 5-Source Merge System

> Source: `src/utils/settings/settings.ts`, `src/utils/settings/constants.ts`

### Source Priority (later = higher)

```typescript
// src/utils/settings/constants.ts:7-22
const SETTING_SOURCES = [
  'userSettings',      // ~/.claude/settings.json
  'projectSettings',   // .claude/settings.json
  'localSettings',     // .claude/settings.local.json (gitignored)
  'flagSettings',      // --settings CLI flag specified file + SDK inline settings
  'policySettings',    // managed-settings.json / MDM / remote policy
] as const
```

### policySettings Internal Priority (first-source-wins)

```typescript
// src/utils/settings/settings.ts:319-345
// policySettings is special: first non-empty source wins
// Priority: remote > HKLM/macOS plist > managed-settings.json > HKCU
function getSettingsForSourceUncached('policySettings') {
  1. getRemoteManagedSettingsSyncFromCache()  // Remote policy received from API
  2. getMdmSettings()                         // macOS: plutil, Windows: HKLM reg
  3. loadManagedFileSettings()                // ~/.claude/managed-settings.json
  4. getHkcuSettings()                        // Windows HKCU (user-level registry)
}
```

### flagSettings Special Handling

```typescript
// src/utils/settings/settings.ts:352-365
// flagSettings = --settings file + SDK inline settings merge
if (source === 'flagSettings') {
  const inlineSettings = getFlagSettingsInline()  // Inline settings injected by SDK
  if (inlineSettings) {
    return mergeWith(fileSettings, parsed.data, settingsMergeCustomizer)
  }
}
```

### Read-Only vs Writable Sources

```typescript
// policySettings and flagSettings are read-only
type EditableSettingSource = Exclude<SettingSource, 'policySettings' | 'flagSettings'>
// → 'userSettings' | 'projectSettings' | 'localSettings'

// policySettings and flagSettings are always loaded (regardless of --setting-sources flag)
function getEnabledSettingSources(): SettingSource[] {
  const allowed = getAllowedSettingSources()  // Can be restricted via CLI flag
  const result = new Set(allowed)
  result.add('policySettings')   // Always included
  result.add('flagSettings')     // Always included
  return Array.from(result)
}
```

---

## 4.6 SettingsJson Full Schema (~100 fields, including feature gates)

> Source: `src/utils/settings/types.ts` — `SettingsSchema()` Zod definition
> `.passthrough()` allows unknown keys (backward compatibility)

### Authentication/Credentials
| Field | Type | Optional | Description |
|------|------|:----:|------|
| `apiKeyHelper` | `string` | ✓ | Script path that outputs auth value |
| `awsCredentialExport` | `string` | ✓ | AWS credential export script |
| `awsAuthRefresh` | `string` | ✓ | AWS auth refresh script |
| `gcpAuthRefresh` | `string` | ✓ | GCP auth refresh command |
| `xaaIdp` | `{ issuer, clientId, callbackPort? }` | ✓ | XAA IdP OIDC config (env-gated) |
| `forceLoginMethod` | `'claudeai' \| 'console'` | ✓ | Force login method |
| `forceLoginOrgUUID` | `string` | ✓ | Organization UUID for OAuth login |

### Permission/Access Control
| Field | Type | Optional | Description |
|------|------|:----:|------|
| `permissions` | `{ allow, deny, ask, defaultMode, disableBypassPermissionsMode, disableAutoMode, additionalDirectories }` | ✓ | Full permission configuration |
| `allowManagedPermissionRulesOnly` | `boolean` | ✓ | managed-settings only rules |
| `skipDangerousModePermissionPrompt` | `boolean` | ✓ | Skip bypass mode dialog |

### MCP Servers
| Field | Type | Optional | Description |
|------|------|:----:|------|
| `enableAllProjectMcpServers` | `boolean` | ✓ | Auto-approve project MCP servers |
| `allowedMcpServers` | `AllowedMcpServerEntry[]` | ✓ | Enterprise allow list |
| `deniedMcpServers` | `DeniedMcpServerEntry[]` | ✓ | Enterprise deny list |
| `allowManagedMcpServersOnly` | `boolean` | ✓ | Managed MCP only |
| `channelsEnabled` | `boolean` | ✓ | Enable MCP channel notifications |

### Hooks/Automation
| Field | Type | Optional | Description |
|------|------|:----:|------|
| `hooks` | `HooksSchema` | ✓ | Custom commands before/after tools |
| `disableAllHooks` | `boolean` | ✓ | Disable all hooks + statusLine |
| `allowManagedHooksOnly` | `boolean` | ✓ | Managed hooks only |
| `allowedHttpHookUrls` | `string[]` | ✓ | HTTP hook URL allow list (`*` supported) |
| `statusLine` | `{ type: 'command', command, padding? }` | ✓ | Custom status line |

### Model Configuration
| Field | Type | Optional | Description |
|------|------|:----:|------|
| `model` | `string` | ✓ | Default Model override |
| `availableModels` | `string[]` | ✓ | Available models allow list |
| `modelOverrides` | `Record<string, string>` | ✓ | Anthropic → provider model ID mapping |
| `advisorModel` | `string` | ✓ | Server-side advisor model |
| `effortLevel` | `'low' \| 'medium' \| 'high' \| 'max'(ant)` | ✓ | Effort level |
| `fastMode` | `boolean` | ✓ | Enable fast mode |

### UI/Display
| Field | Type | Optional | Description |
|------|------|:----:|------|
| `outputStyle` | `string` | ✓ | Response output style |
| `language` | `string` | ✓ | Preferred language |
| `syntaxHighlightingDisabled` | `boolean` | ✓ | Disable syntax highlighting |
| `prefersReducedMotion` | `boolean` | ✓ | Reduced motion (accessibility) |

### Plugins/Marketplace
| Field | Type | Optional | Description |
|------|------|:----:|------|
| `enabledPlugins` | `Record<string, string[] \| boolean>` | ✓ | Enabled plugins |
| `strictKnownMarketplaces` | `MarketplaceSource[]` | ✓ | Marketplace allow list (policy) |
| `blockedMarketplaces` | `MarketplaceSource[]` | ✓ | Marketplace block list (policy) |
| `pluginConfigs` | `Record<string, { mcpServers?, options? }>` | ✓ | Per-plugin configuration |
| `strictPluginOnlyCustomization` | `boolean \| SurfaceName[]` | ✓ | Block non-plugin customization |

### Auto Mode/Classifier (TRANSCRIPT_CLASSIFIER)
| Field | Type | Optional | Description |
|------|------|:----:|------|
| `autoMode` | `{ allow?, soft_deny?, deny?(ant), environment? }` | ✓ | Auto mode classifier config |
| `skipAutoPermissionPrompt` | `boolean` | ✓ | Skip auto mode opt-in dialog |
| `useAutoModeDuringPlan` | `boolean` | ✓ | Use auto mode during plan mode (default: true) |
| `disableAutoMode` | `'disable'` | ✓ | Disable auto mode |

### Other Key Fields
| Field | Type | Optional | Description |
|------|------|:----:|------|
| `cleanupPeriodDays` | `number` | ✓ | Conversation history retention days (default: 30) |
| `worktree` | `{ symlinkDirectories?, sparsePaths? }` | ✓ | git worktree config |
| `attribution` | `{ commit?, pr? }` | ✓ | Custom attribution |
| `autoMemoryEnabled` | `boolean` | ✓ | Enable auto memory |
| `voiceEnabled` | `boolean` | ✓ | Voice mode (VOICE_MODE) |
| `sshConfigs` | `{ id, name, sshHost, sshPort?, ... }[]` | ✓ | SSH configuration |
| `sandbox` | `SandboxSettingsSchema` | ✓ | Sandbox configuration |
| `env` | `Record<string, string>` | ✓ | Session environment variables |

---

## 5. Hook Schemas (Zod)

### 5.1 HookCommand Discriminated Union

4 hook variants using the `type` field as discriminator.

```typescript
/**
 * Hook command schema (Zod discriminatedUnion).
 * Includes only serializable forms (callback hooks excluded).
 */
export const HookCommandSchema: z.ZodDiscriminatedUnion<'type', [
  BashCommandHookSchema,
  PromptHookSchema,
  AgentHookSchema,
  HttpHookSchema,
]>

// ===== Variant 1: command (shell command execution) =====
type BashCommandHook = {
  type: 'command'
  /** Shell command to execute */
  command: string
  /** Permission rule syntax filter (e.g., "Bash(git *)") */
  if?: string
  /** Shell interpreter: 'bash' (default, $SHELL) | 'powershell' (pwsh) */
  shell?: 'bash' | 'powershell'
  /** Timeout (seconds) */
  timeout?: number
  /** Custom status message to display on spinner */
  statusMessage?: string
  /** If true, execute once then remove */
  once?: boolean
  /** If true, background execution (non-blocking) */
  async?: boolean
  /** If true, background execution + wake model on exit code 2 */
  asyncRewake?: boolean
}

// ===== Variant 2: prompt (LLM prompt evaluation) =====
type PromptHook = {
  type: 'prompt'
  /** Prompt to send to LLM. $ARGUMENTS substitutes hook input JSON. */
  prompt: string
  if?: string
  timeout?: number
  /** Model to use (e.g., "claude-sonnet-4-6"). Defaults to small model if unspecified. */
  model?: string
  statusMessage?: string
  once?: boolean
}

// ===== Variant 3: http (HTTP POST request) =====
type HttpHook = {
  type: 'http'
  /** URL to POST hook input JSON to */
  url: string
  if?: string
  timeout?: number
  /** Additional headers. Can reference environment variables via $VAR_NAME. */
  headers?: Record<string, string>
  /** List of environment variable names to interpolate in headers */
  allowedEnvVars?: string[]
  statusMessage?: string
  once?: boolean
}

// ===== Variant 4: agent (agent verifier) =====
type AgentHook = {
  type: 'agent'
  /** Content to verify description. $ARGUMENTS substitutes hook input JSON. */
  prompt: string
  if?: string
  /** Timeout (seconds, default 60) */
  timeout?: number
  /** Model to use (defaults to Haiku if unspecified) */
  model?: string
  statusMessage?: string
  once?: boolean
}
```

### 5.2 HookMatcher & HooksSettings

```typescript
/** Matcher settings: pattern and list of hooks to execute */
export type HookMatcher = {
  /** String pattern to match (e.g., tool name "Write") */
  matcher?: string
  /** List of hooks to execute when matcher matches */
  hooks: HookCommand[]
}

/**
 * Full hook settings shape.
 * Key: HookEvent name, value: HookMatcher array
 */
export type HooksSettings = Partial<Record<HookEvent, HookMatcher[]>>

/**
 * Hook event list (HOOK_EVENTS):
 * PreToolUse, PostToolUse, PostToolUseFailure, Notification,
 * SessionStart, SubagentStart, UserPromptSubmit, Setup,
 * PermissionDenied, PermissionRequest, Stop, Elicitation,
 * ElicitationResult, CwdChanged, FileChanged, WorktreeCreate
 */
```

### 5.3 Hook Result Types

```typescript
/** Individual hook execution result */
export type HookResult = {
  message?: Message
  systemMessage?: Message
  blockingError?: HookBlockingError
  outcome: 'success' | 'blocking' | 'non_blocking_error' | 'cancelled'
  preventContinuation?: boolean
  stopReason?: string
  permissionBehavior?: 'ask' | 'deny' | 'allow' | 'passthrough'
  hookPermissionDecisionReason?: string
  additionalContext?: string
  initialUserMessage?: string
  updatedInput?: Record<string, unknown>
  updatedMCPToolOutput?: unknown
  permissionRequestResult?: PermissionRequestResult
  retry?: boolean
}

/** Aggregated result of multiple hooks */
export type AggregatedHookResult = {
  message?: Message
  blockingErrors?: HookBlockingError[]
  preventContinuation?: boolean
  stopReason?: string
  hookPermissionDecisionReason?: string
  permissionBehavior?: PermissionResult['behavior']
  additionalContexts?: string[]
  initialUserMessage?: string
  updatedInput?: Record<string, unknown>
  updatedMCPToolOutput?: unknown
  permissionRequestResult?: PermissionRequestResult
  retry?: boolean
}

export type HookBlockingError = {
  blockingError: string
  command: string
}

export type HookProgress = {
  type: 'hook_progress'
  hookEvent: HookEvent
  hookName: string
  command: string
  promptText?: string
  statusMessage?: string
}
```

---

## 6. MCP Types

### 6.1 Config Scope & Transport

```typescript
/** Source scope of MCP server configuration */
export type ConfigScope = 'local' | 'user' | 'project' | 'dynamic' | 'enterprise' | 'claudeai' | 'managed'

/** MCP transport protocol */
export type Transport = 'stdio' | 'sse' | 'sse-ide' | 'http' | 'ws' | 'sdk'
```

### 6.2 MCP Server Config (Union)

```typescript
/** stdio transport server config */
export type McpStdioServerConfig = {
  type?: 'stdio'             // Optional for backward compatibility
  command: string
  args?: string[]
  env?: Record<string, string>
}

/** SSE transport server config */
export type McpSSEServerConfig = {
  type: 'sse'
  url: string
  headers?: Record<string, string>
  headersHelper?: string
  oauth?: { clientId?: string; callbackPort?: number; authServerMetadataUrl?: string; xaa?: boolean }
}

/** HTTP Streamable transport server config */
export type McpHTTPServerConfig = {
  type: 'http'
  url: string
  headers?: Record<string, string>
  headersHelper?: string
  oauth?: { clientId?: string; callbackPort?: number; authServerMetadataUrl?: string; xaa?: boolean }
}

/** WebSocket transport server config */
export type McpWebSocketServerConfig = {
  type: 'ws'
  url: string
  headers?: Record<string, string>
  headersHelper?: string
}

/** IDE SSE transport (internal only) */
export type McpSSEIDEServerConfig = { type: 'sse-ide'; url: string; ideName: string; ideRunningInWindows?: boolean }

/** IDE WebSocket transport (internal only) */
export type McpWebSocketIDEServerConfig = { type: 'ws-ide'; url: string; ideName: string; authToken?: string; ideRunningInWindows?: boolean }

/** SDK built-in server */
export type McpSdkServerConfig = { type: 'sdk'; name: string }

/** Claude.ai proxy server */
export type McpClaudeAIProxyServerConfig = { type: 'claudeai-proxy'; url: string; id: string }

/** Union of all server configs */
export type McpServerConfig =
  | McpStdioServerConfig
  | McpSSEServerConfig
  | McpSSEIDEServerConfig
  | McpWebSocketIDEServerConfig
  | McpHTTPServerConfig
  | McpWebSocketServerConfig
  | McpSdkServerConfig
  | McpClaudeAIProxyServerConfig

/** Server config with scope attached */
export type ScopedMcpServerConfig = McpServerConfig & {
  scope: ConfigScope
  pluginSource?: string  // Source of plugin-provided server (e.g., 'slack@anthropic')
}
```

### 6.3 MCPServerConnection (Discriminated Union)

```typescript
/** Successfully connected server */
export type ConnectedMCPServer = {
  client: Client                      // @modelcontextprotocol/sdk Client
  name: string
  type: 'connected'
  capabilities: ServerCapabilities
  serverInfo?: { name: string; version: string }
  instructions?: string
  config: ScopedMcpServerConfig
  cleanup: () => Promise<void>
}

/** Connection failed server */
export type FailedMCPServer = {
  name: string; type: 'failed'; config: ScopedMcpServerConfig; error?: string
}

/** Auth-required server */
export type NeedsAuthMCPServer = {
  name: string; type: 'needs-auth'; config: ScopedMcpServerConfig
}

/** Pending server */
export type PendingMCPServer = {
  name: string; type: 'pending'; config: ScopedMcpServerConfig
  reconnectAttempt?: number; maxReconnectAttempts?: number
}

/** Disabled server */
export type DisabledMCPServer = {
  name: string; type: 'disabled'; config: ScopedMcpServerConfig
}

/** MCP server connection state union (discriminated by type field) */
export type MCPServerConnection =
  | ConnectedMCPServer
  | FailedMCPServer
  | NeedsAuthMCPServer
  | PendingMCPServer
  | DisabledMCPServer

/** Resource belonging to a server */
export type ServerResource = Resource & { server: string }
```

---

## 7. Task Types

### 7.1 TaskType & TaskStatus

```typescript
/** Task type enumeration */
export type TaskType =
  | 'local_bash'             // Local shell command
  | 'local_agent'            // Local agent (subagent)
  | 'remote_agent'           // Remote agent (CCR)
  | 'in_process_teammate'    // In-process teammate (swarm)
  | 'local_workflow'         // Local workflow
  | 'monitor_mcp'            // MCP monitor
  | 'dream'                  // Dream agent

/** Task execution status */
export type TaskStatus =
  | 'pending'     // Pending
  | 'running'     // Running
  | 'completed'   // Completed
  | 'failed'      // Failed
  | 'killed'      // Force killed

/**
 * Check whether this is a terminal status.
 * Returns true if completed | failed | killed.
 * Used to prevent message injection to dead teammates, remove completed tasks, etc.
 */
export function isTerminalTaskStatus(status: TaskStatus): boolean {
  return status === 'completed' || status === 'failed' || status === 'killed'
}
```

### 7.2 TaskStateBase

Common fields for all task states.

```typescript
export type TaskStateBase = {
  id: string              // Created via generateTaskId()
  type: TaskType
  status: TaskStatus
  description: string
  toolUseId?: string      // Tool call ID (for linking)
  startTime: number       // Date.now() timestamp
  endTime?: number
  totalPausedMs?: number
  outputFile: string      // Disk output file path
  outputOffset: number    // Current offset within file
  notified: boolean       // Whether user has been notified
}
```

### 7.3 Seven Concrete Task States

```typescript
/** 1. LocalShellTaskState - Shell command execution */
export type LocalShellTaskState = TaskStateBase & {
  type: 'local_bash'           // Keeping 'local_bash' for backward compatibility
  command: string
  result?: { code: number; interrupted: boolean }
  completionStatusSentInAttachment: boolean
  shellCommand: ShellCommand | null
  kind: BashTaskKind           // 'bash' | 'monitor'
  agentId?: AgentId
  isBackgrounded?: boolean
}

/** 2. LocalAgentTaskState - Subagent execution */
export type LocalAgentTaskState = TaskStateBase & {
  type: 'local_agent'
  agentId: string
  prompt: string
  selectedAgent?: AgentDefinition
  agentType: string
  model?: string
  abortController?: AbortController
  unregisterCleanup?: () => void
}

/** 3. RemoteAgentTaskState - CCR remote agent */
export type RemoteAgentTaskState = TaskStateBase & {
  type: 'remote_agent'
  remoteTaskType: RemoteTaskType
  remoteTaskMetadata?: RemoteTaskMetadata
  sessionId: string
  command: string
  title: string
  todoList: TodoList
}

/** 4. InProcessTeammateTaskState - In-process teammate */
export type InProcessTeammateTaskState = TaskStateBase & {
  type: 'in_process_teammate'
  identity: TeammateIdentity    // { agentId, agentName, teamName, color?, planModeRequired, parentSessionId }
  prompt: string
}

/** 5. LocalWorkflowTaskState - Workflow execution */
export type LocalWorkflowTaskState = TaskStateBase & {
  type: 'local_workflow'
  // Workflow-specific fields
}

/** 6. MonitorMcpTaskState - MCP monitor */
export type MonitorMcpTaskState = TaskStateBase & {
  type: 'monitor_mcp'
  // Monitor-specific fields
}

/** 7. DreamTaskState - Dream agent */
export type DreamTaskState = TaskStateBase & {
  type: 'dream'
  phase: 'starting' | 'updating'
  sessionsReviewing: number
  // Observed Edit/Write paths (incomplete - bash writes not included)
}

/**
 * Union type of all task states.
 * Used when components need to handle all task types.
 */
export type TaskState =
  | LocalShellTaskState
  | LocalAgentTaskState
  | RemoteAgentTaskState
  | InProcessTeammateTaskState
  | LocalWorkflowTaskState
  | MonitorMcpTaskState
  | DreamTaskState
```

---

## 8. Permission Types

### 8.1 PermissionMode

```typescript
/** Permission modes exposed to external users */
export const EXTERNAL_PERMISSION_MODES = [
  'acceptEdits',       // Auto-accept edits
  'bypassPermissions', // Bypass all permissions
  'default',           // Default (ask every time)
  'dontAsk',           // Don't ask
  'plan',              // Plan mode (read-only)
] as const

export type ExternalPermissionMode = (typeof EXTERNAL_PERMISSION_MODES)[number]

/** Including internal-only modes */
export type InternalPermissionMode = ExternalPermissionMode | 'auto' | 'bubble'
export type PermissionMode = InternalPermissionMode

/** Mode set for runtime validation (auto requires TRANSCRIPT_CLASSIFIER feature flag) */
export const INTERNAL_PERMISSION_MODES: readonly PermissionMode[]
```

### 8.2 PermissionResult & PermissionDecision

```typescript
export type PermissionBehavior = 'allow' | 'deny' | 'ask'

/**
 * Permission decision (3 behaviors + passthrough).
 * Returned by tool's checkPermissions().
 */
export type PermissionResult<Input = { [key: string]: unknown }> =
  | PermissionAllowDecision<Input>
  | PermissionAskDecision<Input>
  | PermissionDenyDecision
  | {
      behavior: 'passthrough'
      message: string
      decisionReason?: PermissionDecisionReason
      suggestions?: PermissionUpdate[]
      blockedPath?: string
      pendingClassifierCheck?: PendingClassifierCheck
    }

/** Allow decision */
export type PermissionAllowDecision<Input = { [key: string]: unknown }> = {
  behavior: 'allow'
  updatedInput?: Input
  userModified?: boolean
  decisionReason?: PermissionDecisionReason
  toolUseID?: string
  acceptFeedback?: string
  contentBlocks?: ContentBlockParam[]
}

/** Ask user decision */
export type PermissionAskDecision<Input = { [key: string]: unknown }> = {
  behavior: 'ask'
  message: string
  updatedInput?: Input
  decisionReason?: PermissionDecisionReason
  suggestions?: PermissionUpdate[]
  blockedPath?: string
  metadata?: PermissionMetadata
  isBashSecurityCheckForMisparsing?: boolean
  pendingClassifierCheck?: PendingClassifierCheck
  contentBlocks?: ContentBlockParam[]
}

/** Deny decision */
export type PermissionDenyDecision = {
  behavior: 'deny'
  message: string
  decisionReason: PermissionDecisionReason
  toolUseID?: string
}
```

### 8.3 PermissionDecisionReason

```typescript
/**
 * Reason for permission decision (discriminated union).
 * Discriminated by type field.
 */
export type PermissionDecisionReason =
  | { type: 'rule'; rule: PermissionRule }
  | { type: 'mode'; mode: PermissionMode }
  | { type: 'subcommandResults'; reasons: Map<string, PermissionResult> }
  | { type: 'permissionPromptTool'; permissionPromptToolName: string; toolResult: unknown }
  | { type: 'hook'; hookName: string; hookSource?: string; reason?: string }
  | { type: 'asyncAgent'; reason: string }
  | { type: 'sandboxOverride'; reason: 'excludedCommand' | 'dangerouslyDisableSandbox' }
  | { type: 'classifier'; classifier: string; reason: string }
  | { type: 'workingDir'; reason: string }
  | { type: 'safetyCheck'; reason: string; classifierApprovable: boolean }
  | { type: 'other'; reason: string }
```

### 8.4 Permission Rules

```typescript
/** Source of permission rules */
export type PermissionRuleSource =
  | 'userSettings'     // ~/.claude/settings.json
  | 'projectSettings'  // .claude/settings.json
  | 'localSettings'    // .claude/settings.local.json
  | 'flagSettings'     // --allowedTools CLI flag
  | 'policySettings'   // Enterprise policy
  | 'cliArg'           // CLI argument
  | 'command'          // Added during command execution
  | 'session'          // User approval during session

/** Rule value */
export type PermissionRuleValue = {
  toolName: string
  ruleContent?: string   // The "git *" part in "Bash(git *)"
}

/** Rules mapping by source */
export type ToolPermissionRulesBySource = {
  [T in PermissionRuleSource]?: string[]
}

/** Permission update operations */
export type PermissionUpdate =
  | { type: 'addRules'; destination: PermissionUpdateDestination; rules: PermissionRuleValue[]; behavior: PermissionBehavior }
  | { type: 'replaceRules'; destination: PermissionUpdateDestination; rules: PermissionRuleValue[]; behavior: PermissionBehavior }
  | { type: 'removeRules'; destination: PermissionUpdateDestination; rules: PermissionRuleValue[]; behavior: PermissionBehavior }
  | { type: 'setMode'; destination: PermissionUpdateDestination; mode: ExternalPermissionMode }
  | { type: 'addDirectories'; destination: PermissionUpdateDestination; directories: string[] }
  | { type: 'removeDirectories'; destination: PermissionUpdateDestination; directories: string[] }

export type PermissionUpdateDestination =
  | 'userSettings' | 'projectSettings' | 'localSettings' | 'session' | 'cliArg'
```

### 8.5 Classifier Types

```typescript
/** YOLO classifier result (for auto mode) */
export type YoloClassifierResult = {
  thinking?: string
  shouldBlock: boolean
  reason: string
  unavailable?: boolean
  transcriptTooLong?: boolean
  model: string
  usage?: ClassifierUsage
  durationMs?: number
  promptLengths?: { systemPrompt: number; toolCalls: number; userPrompts: number }
  errorDumpPath?: string
  stage?: 'fast' | 'thinking'
  stage1Usage?: ClassifierUsage
  stage1DurationMs?: number
  stage1RequestId?: string
  stage1MsgId?: string
  stage2Usage?: ClassifierUsage
  stage2DurationMs?: number
  stage2RequestId?: string
  stage2MsgId?: string
}

export type ClassifierUsage = {
  inputTokens: number
  outputTokens: number
  cacheReadInputTokens: number
  cacheCreationInputTokens: number
}
```

---

## 9. Environment Variables

### 9.1 Authentication/API

| Variable | Type | Description |
|--------|------|------|
| `ANTHROPIC_API_KEY` | string | Anthropic API key (direct auth) |
| `ANTHROPIC_CUSTOM_HEADERS` | string | Custom headers to add to API requests (JSON string). May include `Authorization` header |
| `CLAUDE_CODE_ADDITIONAL_PROTECTION` | string | Additional security layer indicator (passed with API requests) |
| `CLAUDE_CODE_OAUTH_TOKEN` | string | OAuth token (environment injected) |
| `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR` | string | OAuth token file descriptor |
| `CLAUDE_CODE_OAUTH_REFRESH_TOKEN` | string | OAuth refresh token |
| `CLAUDE_CODE_OAUTH_SCOPES` | string | OAuth scopes (required when using refresh token) |
| `CLAUDE_CODE_OAUTH_CLIENT_ID` | string | OAuth client ID override |
| `CLAUDE_CODE_CUSTOM_OAUTH_URL` | string | OAuth URL override (restricted to allow list) |
| `CLAUDE_CODE_SESSION_ACCESS_TOKEN` | string | Single-session access token (SSE/WS) |
| `CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR` | string | API key file descriptor |
| `CLAUDE_CODE_API_KEY_HELPER_TTL_MS` | number | API key helper cache TTL (ms) |
| `CLAUDE_CODE_ACCOUNT_UUID` | string | Account UUID |
| `CLAUDE_CODE_USER_EMAIL` | string | User email |
| `CLAUDE_CODE_ORGANIZATION_UUID` | string | Organization UUID |

### 9.2 Backend/Routing

| Variable | Type | Description |
|--------|------|------|
| `CLAUDE_CODE_USE_BEDROCK` | boolean | Use AWS Bedrock |
| `CLAUDE_CODE_USE_VERTEX` | boolean | Use Google Vertex |
| `CLAUDE_CODE_USE_FOUNDRY` | boolean | Use Foundry |
| `CLAUDE_CODE_EXTRA_BODY` | JSON | JSON object to add to API request body |
| `CLAUDE_CODE_EXTRA_METADATA` | JSON | Additional JSON for API request metadata |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | number | Maximum output token count |
| `CLAUDE_CODE_DISABLE_THINKING` | boolean | Disable thinking |
| `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING` | boolean | Disable adaptive thinking |
| `CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK` | boolean | Disable non-streaming fallback |
| `CLAUDE_CODE_DISABLE_FAST_MODE` | boolean | Disable fast mode |
| `CLAUDE_CODE_GB_BASE_URL` | string | GrowthBook API base URL |
| `CLAUDE_INTERNAL_FC_OVERRIDES` | string | GrowthBook feature flag local overrides (JSON string). Example: `'{"my_feature": true, "my_config": {"key": "val"}}'`. Force-set feature flag values to bypass A/B tests |

### 9.3 Session/Mode

| Variable | Type | Description |
|--------|------|------|
| `CLAUDE_CODE_ENTRYPOINT` | string | Entrypoint identification (cli/sdk-ts/sdk-py/local-agent/claude-desktop) |
| `CLAUDE_CODE_SIMPLE` | boolean | Simplified mode (--bare): skip hooks/LSP/plugin sync |
| `CLAUDE_CODE_COORDINATOR_MODE` | boolean | Enable coordinator mode |
| `CLAUDE_CODE_REMOTE` | boolean | Remote execution mode |
| `CLAUDE_CODE_PROACTIVE` | boolean | Proactive mode |
| `CLAUDE_CODE_ACTION` | boolean | GitHub Action environment |
| `CLAUDE_CODE_VERIFY_PLAN` | boolean | Enable plan verification tool |
| `CLAUDE_CODE_RESUME_INTERRUPTED_TURN` | string | Resume interrupted turn |

### 9.4 Remote/Container

| Variable | Type | Description |
|--------|------|------|
| `CLAUDE_CODE_HOST_PLATFORM` | string | Host platform override (for containers) |
| `CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE` | string | Remote environment type |
| `CLAUDE_CODE_CONTAINER_ID` | string | Container ID |
| `CLAUDE_CODE_REMOTE_SESSION_ID` | string | Remote session ID |
| `CLAUDE_CODE_ENVIRONMENT_RUNNER_VERSION` | string | Environment runner version |
| `CLAUDE_CODE_ENVIRONMENT_KIND` | string | Environment kind ('bridge', etc.) |
| `CLAUDE_CODE_WORKER_EPOCH` | string | Worker epoch (CCR v2) |
| `CLAUDE_CODE_USE_CCR_V2` | boolean | Use CCR v2 transport |
| `CLAUDE_CODE_POST_FOR_SESSION_INGRESS_V2` | boolean | Use hybrid transport |
| `CLAUDE_CODE_CCR_MIRROR` | boolean | Enable CCR mirroring |

### 9.5 Feature/Debug

| Variable | Type | Description |
|--------|------|------|
| `CLAUDE_CODE_OVERRIDE_DATE` | string | Date override (YYYY-MM-DD) |
| `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS` | boolean | Disable background tasks |
| `CLAUDE_CODE_DISABLE_COMMAND_INJECTION_CHECK` | boolean | Disable command injection check |
| `CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY` | number | Max tool parallel execution count (default: 10) |
| `CLAUDE_CODE_DEBUG_REPAINTS` | boolean | Debug UI repaints |
| `CLAUDE_CODE_COMMIT_LOG` | string | Commit log path |
| `CLAUDE_CODE_BUBBLEWRAP` | boolean | Enable Bubblewrap sandbox |
| `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD` | boolean | Load CLAUDE.md from additional directories |
| `CLAUDE_CODE_ATTRIBUTION_HEADER` | boolean | Commit attribution header |
| `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION` | boolean | Enable prompt suggestions |
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | string | Auto compaction window |
| `CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE` | string | Blocking limit override |
| `CLAUDE_CODE_EAGER_FLUSH` | boolean | Eager flush |
| `CLAUDE_CODE_IS_COWORK` | boolean | Cowork mode |
| `CLAUDE_CODE_STREAMLINED_OUTPUT` | boolean | Streamlined output (for stream-json) |
| `CLAUDE_CODE_TAGS` | string | Session tags |
| `CLAUDE_CODE_EXIT_AFTER_FIRST_RENDER` | boolean | Exit after first render (for testing) |
| `CLAUDE_CODE_DISABLE_POLICY_SKILLS` | boolean | Disable policy skills |
| `CLAUDE_CODE_COWORKER_TYPE` | string | Coworker type telemetry |

### 9.6 Plugin/Sync

| Variable | Type | Description |
|--------|------|------|
| `CLAUDE_CODE_SYNC_PLUGIN_INSTALL` | boolean | Synchronous plugin installation |
| `CLAUDE_CODE_SYNC_PLUGIN_INSTALL_TIMEOUT_MS` | number | Synchronous plugin install timeout |
| `CLAUDE_CODE_PLUGIN_SEED_DIR` | string | Plugin seed directory |

### 9.7 Agent SDK

| Variable | Type | Description |
|--------|------|------|
| `CLAUDE_AGENT_SDK_VERSION` | string | Agent SDK version |
| `CLAUDE_CODE_AGENT_ID` | string | Agent ID (agentName@teamName) |
| `CLAUDE_CODE_PARENT_SESSION_ID` | string | Parent session ID (team leader's session) |
| `CLAUDE_CODE_AGENT_NAME` | string | Agent name |
| `CLAUDE_CODE_STREAM_CLOSE_TIMEOUT` | number | Stream close timeout (for MCP calls exceeding 60s) |
| `CLAUDE_CODE_DATADOG_FLUSH_INTERVAL_MS` | number | Datadog flush interval (ms) |
| `CLAUDE_CODE_TEST_FIXTURES_ROOT` | string | Test fixtures root directory |
| `CLAUDE_CODE_EMIT_TOOL_USE_SUMMARIES` | boolean | Emit tool use summaries |

---

## 10. Feature Flags

Feature flags evaluated at build time using the `feature()` macro (`bun:bundle`). Dynamically controlled via GrowthBook.

| Flag Name | Description |
|-------------|------|
| `TRANSCRIPT_CLASSIFIER` | Auto permission classifier (auto mode). Transcript-based tool call safety assessment. |
| `BASH_CLASSIFIER` | Bash command-specific classifier. Auto-detect dangerous commands. |
| `TREE_SITTER_BASH_SHADOW` | Tree-sitter-based Bash parser (shadow mode). |
| `PROACTIVE` | Proactive mode. Model proactively suggests tasks. |
| `KAIROS` | Assistant mode (full features). Channel integration, session management, etc. |
| `KAIROS_BRIEF` | Assistant brief mode (lightweight). |
| `KAIROS_CHANNELS` | Kairos channel features. |
| `COORDINATOR_MODE` | Coordinator mode. Orchestrates multiple workers. |
| `CACHED_MICROCOMPACT` | Cached micro compaction. Improves prompt cache efficiency. |
| `CONTEXT_COLLAPSE` | Context collapse. Replaces old conversations with summaries. |
| `REACTIVE_COMPACT` | Reactive compaction. Auto-compress when approaching token limit. |
| `HISTORY_SNIP` | Previous conversation snipping. |
| `TOKEN_BUDGET` | Token budget tracking. Usage monitoring. |
| `BG_SESSIONS` | Background session support. Integrates with `claude ps`. |
| `EXTRACT_MEMORIES` | Auto memory extraction. Saves key information at session end. |
| `TEMPLATES` | Job classifier/templates. |
| `EXPERIMENTAL_SKILL_SEARCH` | Experimental skill search. |
| `VERIFICATION_AGENT` | Plan verification agent. |
| `VOICE_MODE` | Voice mode. Voice input/output support. |
| `BRIDGE_MODE` | Bridge mode. Remote control connection. |
| `CCR_AUTO_CONNECT` | CCR auto-connect. |
| `CCR_MIRROR` | CCR mirroring. |
| `WEB_BROWSER_TOOL` | WebBrowser tool (codename: bagel). |
| `CHICAGO_MCP` | Computer Use MCP tool (macOS native automation). |
| `MONITOR_TOOL` | Monitor tool. Observe long-running processes. |
| `WORKFLOW_SCRIPTS` | Workflow script execution. |
| `AGENT_TRIGGERS` | Agent triggers (scheduled cron). |
| `ULTRAPLAN` | Ultraplan (CCR-based large-scale planning). |
| `BUDDY` | Companion feature (pet character). |
| `COMMIT_ATTRIBUTION` | Commit attribution tracking. |
| `AWAY_SUMMARY` | Away summary. |
| `MESSAGE_ACTIONS` | Message actions (edit/copy, etc.). |
| `HOOK_PROMPTS` | Hook prompt elicitation. |
| `LODESTONE` | Lodestone feature. |
| `CONNECTOR_TEXT` | Connector text beta. |
| `ENABLE_AGENT_SWARMS` | Agent swarms (team features). |
| `TEAMMEM` | Team memory (cross-session team knowledge sharing). |
| `NATIVE_CLIENT_ATTESTATION` | Native client attestation. |
| `IS_LIBC_MUSL` | musl libc detection (Alpine, etc.). |
| `IS_LIBC_GLIBC` | glibc detection. |
| `COWORKER_TYPE_TELEMETRY` | Coworker type telemetry. |

---

## 11. Analytics Event Names

Analytics events using the `tengu_` prefix. Used in the Datadog gate list and 1st-party event logger.

```typescript
/** List of events forwarded to Datadog */
const DATADOG_EVENTS = [
  // ===== API =====
  'tengu_api_error',           // API call error
  'tengu_api_success',         // API call success

  // ===== Session =====
  'tengu_init',                // Initialization
  'tengu_started',             // Session start
  'tengu_exit',                // Session end
  'tengu_cancel',              // User cancellation

  // ===== Query =====
  'tengu_query_error',         // Query error

  // ===== Tool Use =====
  'tengu_tool_use_error',                          // Tool use error
  'tengu_tool_use_success',                        // Tool use success
  'tengu_tool_use_granted_in_prompt_permanent',    // Permanent grant
  'tengu_tool_use_granted_in_prompt_temporary',    // Temporary grant
  'tengu_tool_use_rejected_in_prompt',             // Rejected in prompt

  // ===== Brief/SendUserMessage =====
  'tengu_brief_mode_enabled',  // Brief mode activated
  'tengu_brief_mode_toggled',  // Brief mode toggled
  'tengu_brief_send',          // Brief message sent

  // ===== Compaction =====
  'tengu_compact_failed',      // Compaction failed

  // ===== OAuth =====
  'tengu_oauth_error',
  'tengu_oauth_success',
  'tengu_oauth_token_refresh_failure',
  'tengu_oauth_token_refresh_success',
  'tengu_oauth_token_refresh_lock_acquiring',
  'tengu_oauth_token_refresh_lock_acquired',
  'tengu_oauth_token_refresh_starting',
  'tengu_oauth_token_refresh_completed',
  'tengu_oauth_token_refresh_lock_releasing',
  'tengu_oauth_token_refresh_lock_released',

  // ===== Session File =====
  'tengu_session_file_read',   // Session file read

  // ===== Errors =====
  'tengu_uncaught_exception',  // Uncaught exception
  'tengu_unhandled_rejection', // Unhandled promise rejection

  // ===== Model =====
  'tengu_model_fallback_triggered', // Model fallback triggered

  // ===== UI =====
  'tengu_flicker',             // UI flicker detected

  // ===== Voice =====
  'tengu_voice_recording_started', // Voice recording started
  'tengu_voice_toggled',           // Voice toggled

  // ===== Team Memory =====
  'tengu_team_mem_sync_pull',      // Team memory pull
  'tengu_team_mem_sync_push',      // Team memory push
  'tengu_team_mem_sync_started',   // Team memory sync started
  'tengu_team_mem_entries_capped', // Team memory entries cap reached
] as const
```

### Additional Event Classification

```typescript
// Events included in Datadog event array (also sent to Datadog)
'tengu_api_error'              // API error (explicitly included in datadog.ts)
'tengu_api_success'            // API success (explicitly included in datadog.ts)

// 1st-party event logger only events (not forwarded to Datadog)
// Appears as example in firstPartyEventLogger.ts logEvent()
'tengu_api_query'              // API query execution (logged at request time)
'tengu_run_hook'               // Hook execution
'tengu_auto_mode_decision'     // Auto mode classifier decision
'tengu_backseat_*'             // Backseat observer events
```

> **Correction**: `tengu_api_query` is an example event name from `firstPartyEventLogger.ts`, not from the Datadog event array.
> `tengu_api_success` and `tengu_api_error` are explicitly included as Datadog forwarding targets in `datadog.ts`.

---

## 12. Constants

### 12.1 Tool Name Constants

```typescript
// ===== Core Tools =====
const BASH_TOOL_NAME          = 'Bash'
const POWERSHELL_TOOL_NAME    = 'PowerShell'
const FILE_READ_TOOL_NAME     = 'Read'
const FILE_EDIT_TOOL_NAME     = 'Edit'
const FILE_WRITE_TOOL_NAME    = 'Write'
const GREP_TOOL_NAME          = 'Grep'
const GLOB_TOOL_NAME          = 'Glob'
const NOTEBOOK_EDIT_TOOL_NAME = 'NotebookEdit'

// ===== Agent/Task =====
const AGENT_TOOL_NAME         = 'Agent'
const LEGACY_AGENT_TOOL_NAME  = 'Task'      // Backward compatibility
const TASK_OUTPUT_TOOL_NAME   = 'TaskOutput'
const TASK_STOP_TOOL_NAME     = 'TaskStop'
const TASK_CREATE_TOOL_NAME   = 'TaskCreate'
const TASK_GET_TOOL_NAME      = 'TaskGet'
const TASK_LIST_TOOL_NAME     = 'TaskList'
const TASK_UPDATE_TOOL_NAME   = 'TaskUpdate'
const SEND_MESSAGE_TOOL_NAME  = 'SendMessage'

// ===== Web/Search =====
const WEB_SEARCH_TOOL_NAME    = 'WebSearch'
const WEB_FETCH_TOOL_NAME     = 'WebFetch'
const TOOL_SEARCH_TOOL_NAME   = 'ToolSearch'

// ===== Plan Mode =====
const ENTER_PLAN_MODE_TOOL_NAME      = 'EnterPlanMode'
const EXIT_PLAN_MODE_V2_TOOL_NAME    = 'ExitPlanMode'

// ===== Worktree =====
const ENTER_WORKTREE_TOOL_NAME = 'EnterWorktree'
const EXIT_WORKTREE_TOOL_NAME  = 'ExitWorktree'

// ===== Miscellaneous =====
const SKILL_TOOL_NAME             = 'Skill'
const TODO_WRITE_TOOL_NAME        = 'TodoWrite'
const CONFIG_TOOL_NAME            = 'Config'
const REPL_TOOL_NAME              = 'REPL'
const BRIEF_TOOL_NAME             = 'SendUserMessage'
const LEGACY_BRIEF_TOOL_NAME      = 'Brief'
const SLEEP_TOOL_NAME             = 'Sleep'
const LSP_TOOL_NAME               = 'LSP'
const WORKFLOW_TOOL_NAME          = 'Workflow'   // When feature('WORKFLOW_SCRIPTS')
const REMOTE_TRIGGER_TOOL_NAME    = 'RemoteTrigger'
const SYNTHETIC_OUTPUT_TOOL_NAME  = 'StructuredOutput'
const ASK_USER_QUESTION_TOOL_NAME = 'AskUserQuestion'
const TEAM_CREATE_TOOL_NAME       = 'TeamCreate'
const TEAM_DELETE_TOOL_NAME       = 'TeamDelete'
const CRON_CREATE_TOOL_NAME       = 'CronCreate'
const CRON_DELETE_TOOL_NAME       = 'CronDelete'
const CRON_LIST_TOOL_NAME         = 'CronList'

// ===== Shell Tool Name Set =====
const SHELL_TOOL_NAMES = [BASH_TOOL_NAME, POWERSHELL_TOOL_NAME]
```

### 12.2 Agent Tool Restrictions

```typescript
/**
 * Tools blocked from all agents.
 * Prevents recursion, isolates main-thread-only features.
 */
const ALL_AGENT_DISALLOWED_TOOLS = new Set([
  'TaskOutput',
  'ExitPlanMode',
  'EnterPlanMode',
  'Agent',           // Only allowed when USER_TYPE=ant
  'AskUserQuestion',
  'TaskStop',
  'Workflow',        // When WORKFLOW_SCRIPTS enabled
])

/**
 * Tools allowed for async agents.
 * Read, WebSearch, TodoWrite, Grep, WebFetch, Glob, Bash, PowerShell,
 * Edit, Write, NotebookEdit, Skill, StructuredOutput, ToolSearch,
 * EnterWorktree, ExitWorktree
 */
const ASYNC_AGENT_ALLOWED_TOOLS: Set<string>

/**
 * Additional tools allowed for in-process teammates.
 * TaskCreate, TaskGet, TaskList, TaskUpdate, SendMessage,
 * CronCreate, CronDelete, CronList (when AGENT_TRIGGERS enabled)
 */
const IN_PROCESS_TEAMMATE_ALLOWED_TOOLS: Set<string>

/** Coordinator mode allowed tools (output + agent management only) */
const COORDINATOR_MODE_ALLOWED_TOOLS = new Set([
  'Agent', 'TaskStop', 'SendMessage', 'StructuredOutput',
])

/**
 * Special agent types.
 * ONE_SHOT: execute once and return report (skip agentId/SendMessage/usage trailer).
 */
const VERIFICATION_AGENT_TYPE = 'verification'
const ONE_SHOT_BUILTIN_AGENT_TYPES = new Set(['Explore', 'Plan'])
```

### 12.3 Size Limit Constants

```typescript
// ===== Tool Result Size =====
/** Tool result disk storage threshold (chars). Exceeding saves to file + preview. */
const DEFAULT_MAX_RESULT_SIZE_CHARS = 50_000

/** Maximum tool result token count. ~400KB text. */
const MAX_TOOL_RESULT_TOKENS = 100_000

/** Estimated bytes per token ratio */
const BYTES_PER_TOKEN = 4

/** Maximum tool result bytes (derived from token limit) */
const MAX_TOOL_RESULT_BYTES = MAX_TOOL_RESULT_TOKENS * BYTES_PER_TOKEN  // 400_000

/** Maximum total chars for tool results in a single message (prevents N parallel tools) */
const MAX_TOOL_RESULTS_PER_MESSAGE_CHARS = 200_000

/** Maximum tool summary length */
const TOOL_SUMMARY_MAX_LENGTH = 50

// ===== Image Limits =====
/** API max base64 image size */
const API_IMAGE_MAX_BASE64_SIZE = 5 * 1024 * 1024      // 5MB

/** Target raw size after client-side resizing */
const IMAGE_TARGET_RAW_SIZE = (5 * 1024 * 1024 * 3) / 4  // 3.75MB

/** Maximum image resolution */
const IMAGE_MAX_WIDTH = 2000
const IMAGE_MAX_HEIGHT = 2000

// ===== PDF Limits =====
/** PDF target raw size (within 32MB API limit after base64 encoding) */
const PDF_TARGET_RAW_SIZE = 20 * 1024 * 1024              // 20MB

/** API PDF max page count */
const API_PDF_MAX_PAGES = 100

/** PDF image extraction switch threshold size */
const PDF_EXTRACT_SIZE_THRESHOLD = 3 * 1024 * 1024        // 3MB

/** PDF max extraction size */
const PDF_MAX_EXTRACT_SIZE = 100 * 1024 * 1024            // 100MB

/** Read tool PDF max pages per call */
const PDF_MAX_PAGES_PER_READ = 20

/** @ mention inline PDF threshold pages */
const PDF_AT_MENTION_INLINE_THRESHOLD = 10

// ===== Media Limits =====
/** Max media items per request (images + PDFs) */
const API_MAX_MEDIA_PER_REQUEST = 100
```

### 12.4 Beta Headers

```typescript
const CLAUDE_CODE_20250219_BETA_HEADER = 'claude-code-20250219'
```

### 12.5 UI Icon Constants

```typescript
const BLACK_CIRCLE      = '⏺' | '●'     // macOS vs others
const BULLET_OPERATOR   = '∙'
const LIGHTNING_BOLT    = '↯'              // Fast mode
const PAUSE_ICON        = '⏸'              // Plan mode
const PLAY_ICON         = '▶'
const REFRESH_ARROW     = '↻'              // Resource update
const CHANNEL_ARROW     = '←'              // Inbound channel message
const FORK_GLYPH        = '⑂'              // Fork indicator
const FLAG_ICON         = '⚑'              // Issue flag
const BLOCKQUOTE_BAR    = '▎'              // Blockquote prefix
const REFERENCE_MARK    = '※'              // Away summary marker

// Effort level indicators
const EFFORT_LOW    = '○'
const EFFORT_MEDIUM = '◐'
const EFFORT_HIGH   = '●'
const EFFORT_MAX    = '◉'                  // Opus 4.6 only
```

### 12.6 PluginError Discriminated Union

```typescript
/**
 * Plugin error types (25 variants).
 * Discriminated by type field. Source file: src/types/plugin.ts
 *
 * Key error types:
 * - 'generic-error'              | Generic error
 * - 'plugin-not-found'           | Plugin not found in marketplace
 * - 'path-not-found'             | Path not found
 * - 'git-auth-failed'            | Git auth failed
 * - 'git-timeout'                | Git Timeout
 * - 'network-error'              | Network error
 * - 'manifest-parse-error'       | Manifest parse error
 * - 'manifest-validation-error'  | Manifest validation error
 * - 'marketplace-not-found'      | Marketplace not found
 * - 'marketplace-load-failed'    | Marketplace load failed
 * - 'marketplace-blocked-by-policy' | Marketplace blocked by policy
 * - 'mcp-config-invalid'         | MCP config invalid
 * - 'mcp-server-suppressed-duplicate' | MCP server duplicate suppressed
 * - 'hook-load-failed'           | Hook load failed
 * - 'component-load-failed'      | Component load failed
 * - 'mcpb-download-failed'       | MCPB download failed
 * - 'mcpb-extract-failed'        | MCPB extract failed
 * - 'mcpb-invalid-manifest'      | MCPB manifest invalid
 * - 'lsp-config-invalid'         | LSP config invalid
 * - 'lsp-server-start-failed'    | LSP server start failed
 * - 'lsp-server-crashed'         | LSP server crashed
 * - 'lsp-request-timeout'        | LSP request timeout
 * - 'lsp-request-failed'         | LSP request failed
 * - 'dependency-unsatisfied'     | Dependency unsatisfied
 * - 'plugin-cache-miss'          | Plugin cache miss
 */
export type PluginError = /* discriminated union of 25 variants */
```

---

## Implementation Caveats

### C1. Settings Merge — Shallow Comment vs Actual Deep Merge
Code comments say "Shallow-merge top-level keys," but the actual implementation uses `mergeWith(settingsMergeCustomizer)` — **deep merge + array concat**. Partial overriding of nested objects is not possible, and arrays are always concatenated.

### C2. Bootstrap State Non-Atomicity
Reading across 107 State fields is not atomic. Another agent may write between consecutive reads of two fields. A snapshot method should be implemented if consistent multi-field reads are required.

### C3. Datadog Batch Failure — Event Loss
On batch flush failure, retries with quadratic backoff, but **events are dropped** when maxAttempts is exceeded. Unsent events are not recovered on session restart. No persistent queue.

### C4. Migration Downgrade Safety
Unexpected behavior may occur when an older version reads settings written by a newer version. There is no migration rollback mechanism. Manual settings.json inspection is required when downgrading the CLI.

---

## Appendix: DeepImmutable\<T\>

TypeScript utility type. Recursively converts all properties to `readonly`.

```typescript
/**
 * Deep immutable wrapper.
 * Map -> ReadonlyMap, Set -> ReadonlySet, Array -> ReadonlyArray,
 * object -> all keys readonly + values recursively DeepImmutable.
 * Function types are not transformed (tasks in AppState, etc. are handled separately).
 */
export type DeepImmutable<T> =
  T extends Map<infer K, infer V> ? ReadonlyMap<K, DeepImmutable<V>> :
  T extends Set<infer V> ? ReadonlySet<DeepImmutable<V>> :
  T extends ReadonlyArray<infer V> ? ReadonlyArray<DeepImmutable<V>> :
  T extends object ? { readonly [K in keyof T]: DeepImmutable<T[K]> } :
  T
```

---

> **Note**: All type definitions in this document are based on exact forms extracted from source code and written to be copy-pasteable into new projects. `import` paths and runtime implementations need to be adjusted to match the project structure.
