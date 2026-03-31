# Part 7: Services & Infrastructure

> Reverse engineering design document for the Claude Code CLI service layer and infrastructure architecture

## Table of Contents

1. [API Client Factory](#1-api-client-factory)
2. [API Request Orchestration](#2-api-request-orchestration)
3. [Error Handling](#3-error-handling)
4. [Analytics System](#4-analytics-system)
5. [Context Compression](#5-context-compression)
6. [OAuth System](#6-oauth-system)
7. [Policy & Settings](#7-policy--settings)
8. [Token Estimation](#8-token-estimation)
9. [Migration System](#9-migration-system)
10. [Bootstrap](#10-bootstrap)
11. [CLI Layer](#11-cli-layer)

---

## 1. API Client Factory

> Source: `src/services/api/client.ts` (389 lines)

### 1.1 Architecture Overview

A factory pattern that selects among 4 backend providers based on environment variables. The single entry point `getAnthropicClient()` creates and returns provider-specific SDK instances.

```
┌─────────────────────────────────────────────────────────┐
│               getAnthropicClient()                      │
│                                                          │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────────┐ │
│  │ Direct   │ │ Bedrock  │ │ Foundry  │ │  Vertex    │ │
│  │ (1P API) │ │ (AWS)    │ │ (Azure)  │ │  (GCP)     │ │
│  └──────────┘ └──────────┘ └──────────┘ └────────────┘ │
│       ▲              ▲            ▲            ▲        │
│       │              │            │            │        │
│  ANTHROPIC_     CLAUDE_CODE_  CLAUDE_CODE_  CLAUDE_CODE_│
│  API_KEY        USE_BEDROCK   USE_FOUNDRY   USE_VERTEX  │
└─────────────────────────────────────────────────────────┘
```

### 1.2 Provider Selection Logic

```typescript
// Priority chain (first-come-first-served - first truthy environment variable wins)
function selectProvider(): 'bedrock' | 'foundry' | 'vertex' | 'firstParty' {
  if (isEnvTruthy(process.env.CLAUDE_CODE_USE_BEDROCK)) return 'bedrock'
  if (isEnvTruthy(process.env.CLAUDE_CODE_USE_FOUNDRY)) return 'foundry'
  if (isEnvTruthy(process.env.CLAUDE_CODE_USE_VERTEX))  return 'vertex'
  return 'firstParty'
}
```

### 1.3 Client Creation Interface

```typescript
interface GetAnthropicClientParams {
  apiKey?: string              // Explicit API key (optional)
  maxRetries: number           // SDK-level retry count
  model?: string               // Model name (used for region determination)
  fetchOverride?: ClientOptions['fetch']  // Custom fetch function
  source?: string              // Call origin (for debugging)
}

// Returns: Anthropic SDK instance (all providers cast to Anthropic type)
async function getAnthropicClient(params): Promise<Anthropic>
```

### 1.4 Common Header Configuration

Default headers commonly applied to all providers:

```typescript
const defaultHeaders = {
  'x-app': 'cli',
  'User-Agent': getUserAgent(),                        // UA including version
  'X-Claude-Code-Session-Id': getSessionId(),          // Session ID
  // Conditional headers
  'x-claude-remote-container-id': containerId,         // CCR container
  'x-claude-remote-session-id': remoteSessionId,       // Remote session
  'x-client-app': clientApp,                           // SDK consumer app name
  'x-anthropic-additional-protection': 'true',         // Additional protection (opt-in)
}
```

**Custom header parsing** (`ANTHROPIC_CUSTOM_HEADERS` environment variable):
- Split by newline (`\n`, `\r\n`)
- `Name: Value` format (curl style)
- Split at the first colon (colons allowed in values)

### 1.5 Per-Provider Configuration

#### Direct API (1st Party)

```typescript
{
  apiKey: isClaudeAISubscriber() ? null : apiKey || getAnthropicApiKey(),
  authToken: isClaudeAISubscriber() ? oauthAccessToken : undefined,
  baseURL: /* determined by OAuth config in staging */,
  timeout: parseInt(process.env.API_TIMEOUT_MS || '600000'),
  dangerouslyAllowBrowser: true,
}
```

Authentication priority:
1. OAuth subscriber: `authToken` (OAuth access token)
2. API key user: `apiKey` parameter → `ANTHROPIC_API_KEY` environment variable
3. API Key Helper: acquire key from external process (non-interactive session)
4. `ANTHROPIC_AUTH_TOKEN`: Bearer token header

#### AWS Bedrock

```typescript
{
  awsRegion: /* per-model region or default */,
  awsAccessKey: cachedCredentials.accessKeyId,
  awsSecretKey: cachedCredentials.secretAccessKey,
  awsSessionToken: cachedCredentials.sessionToken,
  // or
  skipAuth: true,  // CLAUDE_CODE_SKIP_BEDROCK_AUTH
  Authorization: `Bearer ${AWS_BEARER_TOKEN_BEDROCK}`,  // Bearer auth
}
```

Region determination priority:
1. `ANTHROPIC_SMALL_FAST_MODEL_AWS_REGION` (Haiku-specific)
2. `AWS_REGION` / `AWS_DEFAULT_REGION`
3. Default: `us-east-1`

#### Azure Foundry

```typescript
{
  // Resource: ANTHROPIC_FOUNDRY_RESOURCE or ANTHROPIC_FOUNDRY_BASE_URL
  azureADTokenProvider: /* 3 paths */,
}
```

Authentication paths:
1. `ANTHROPIC_FOUNDRY_API_KEY` → SDK handles automatically
2. `CLAUDE_CODE_SKIP_FOUNDRY_AUTH` → mock returning empty string
3. `DefaultAzureCredential` → Azure AD automatic authentication

#### Google Vertex AI

```typescript
{
  region: getVertexRegionForModel(model),  // Per-model region
  googleAuth: new GoogleAuth({
    scopes: ['https://www.googleapis.com/auth/cloud-platform'],
    projectId: /* conditional fallback */,
  }),
}
```

Region determination priority:
1. `VERTEX_REGION_CLAUDE_3_5_HAIKU` and other per-model variables
2. `CLOUD_ML_REGION` global variable
3. Configuration default region
4. Fallback: `us-east5`

Preventing 12-second timeout on project ID resolution:
- If `GCLOUD_PROJECT`/`GOOGLE_CLOUD_PROJECT` exists → SDK handles it
- If `GOOGLE_APPLICATION_CREDENTIALS` exists → SDK handles it
- If neither exists → pass `ANTHROPIC_VERTEX_PROJECT_ID` as fallback

### 1.6 Fetch Wrapper (buildFetch)

Automatically injects `x-client-request-id` UUID into all requests:

```typescript
function buildFetch(fetchOverride, source): ClientOptions['fetch'] {
  return (input, init) => {
    const headers = new Headers(init?.headers)
    // 1P API only — risk of rejection by 3P proxies for unsupported headers
    if (injectClientRequestId && !headers.has(CLIENT_REQUEST_ID_HEADER)) {
      headers.set(CLIENT_REQUEST_ID_HEADER, randomUUID())
    }
    // Debug log: URL path + request ID + source
    logForDebugging(`[API REQUEST] ${pathname} ${id} source=${source}`)
    return inner(input, { ...init, headers })
  }
}
```

---

## 2. API Request Orchestration

> Source: `src/services/api/claude.ts` (3,419 lines)

### 2.1 Full Request Pipeline

```
┌──────────────────────────────────────────────────────────────┐
│                    queryModel() Main Loop                        │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  1. Off-switch check (GrowthBook gate for Opus PAYG)             │
│  2. Bedrock inference profile resolution (see 2.1.1 below)       │
│  3. Beta header composition (getMergedBetas)                     │
│  4. Advisor model determination                                  │
│  5. Tool Search activation decision                              │
│  6. Tool schema build (including defer_loading)                   │
│  7. Message normalization (normalizeMessagesForAPI)               │
│  8. Tool pair validation (ensureToolResultPairing)                │
│  9. Media item limitation (stripExcessMediaItems, max 100)        │
│  10. Fingerprint calculation (first user message)                 │
│  11. System Prompt Assembly                                      │
│  12. Cache breakpoint placement                                  │
│  13. Streaming request + withRetry                               │
│  14. Response parsing + usage tracking                           │
│  15. Non-streaming fallback                                      │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### 2.1.1 Bedrock Inference Profile Resolution

```typescript
// src/services/api/claude.ts:1057-1062
// Trigger: getAPIProvider() === 'bedrock' AND model.includes('application-inference-profile')
const resolvedModel =
  getAPIProvider() === 'bedrock' && options.model.includes('application-inference-profile')
    ? (await getInferenceProfileBackingModel(options.model)) ?? options.model
    : options.model

// src/utils/model/bedrock.ts:141-176 — memoized function
async function getInferenceProfileBackingModel(profileId: string): Promise<string | null> {
  // 1. Create BedrockClient (AWS_REGION || 'us-east-1', ANTHROPIC_BEDROCK_BASE_URL option)
  // 2. Send GetInferenceProfileCommand({ inferenceProfileIdentifier: profileId })
  // 3. Extract model name after last '/' from response.models[0].modelArn
  //    e.g.: "arn:aws:bedrock:...:foundation-model/anthropic.claude-opus-4-6-..." → "anthropic.claude-opus-4-6-..."
  // 4. On failure: logError + return null (caller falls back to original model string)
}

// Downstream usage:
// - Token counting: countBedrockTokens() uses resolvedModel (profile IDs are rejected by CountTokens API)
// - Cost calculation: look up cost with resolvedModel; original model used for session cost logging
```

### 2.2 Options Interface

```typescript
type Options = {
  getToolPermissionContext: () => Promise<ToolPermissionContext>
  model: string
  toolChoice?: BetaToolChoiceTool | BetaToolChoiceAuto
  isNonInteractiveSession: boolean
  extraToolSchemas?: BetaToolUnion[]
  maxOutputTokensOverride?: number
  fallbackModel?: string
  onStreamingFallback?: () => void
  querySource: QuerySource          // 'repl_main_thread', 'agent:*', 'sdk', etc.
  agents: AgentDefinition[]
  allowedAgentTypes?: string[]
  hasAppendSystemPrompt: boolean
  fetchOverride?: ClientOptions['fetch']
  enablePromptCaching?: boolean
  skipCacheWrite?: boolean
  temperatureOverride?: number
  effortValue?: EffortValue         // 'high' | 'medium' | 'low' | number
  mcpTools: Tools
  hasPendingMcpServers?: boolean
  queryTracking?: QueryChainTracking
  agentId?: AgentId                 // Subagent only
  outputFormat?: BetaJSONOutputFormat
  fastMode?: boolean
  advisorModel?: string
  addNotification?: (notif: Notification) => void
  taskBudget?: { total: number; remaining?: number }
}
```

### 2.3 System Prompt Assembly

```typescript
// Assembly order (array concatenation)
systemPrompt = [
  getAttributionHeader(fingerprint),     // Fingerprint-based attribution header
  getCLISyspromptPrefix({...}),          // CLI-specific prefix
  ...originalSystemPrompt,              // Caller-provided system prompt
  ...(advisorModel ? [ADVISOR_TOOL_INSTRUCTIONS] : []),  // Advisor instructions
  ...(chromeToolSearch ? [CHROME_TOOL_SEARCH_INSTRUCTIONS] : []),
].filter(Boolean)
```

### 2.4 Prompt Caching Strategy

```typescript
// Cache control block generation
function getCacheControl({ scope, querySource }): {
  type: 'ephemeral'
  ttl?: '1h'          // 1-hour TTL (when subscriber + allowlist match)
  scope?: 'global'    // Global cache scope (when no MCP tools)
}

// 1-hour TTL eligibility determination (session-stable latch)
function should1hCacheTTL(querySource): boolean {
  // 1. Bedrock users: ENABLE_PROMPT_CACHING_1H_BEDROCK opt-in
  // 2. 1P users: ant type or (subscriber AND not using overage)
  // 3. querySource matches GrowthBook allowlist pattern
  //    e.g.: ["repl_main_thread*", "sdk", "agent:*"]
}
```

**Global cache strategy (GlobalCacheStrategy)**:
- `'system_prompt'`: Place global scope marker on system prompt (when no MCP tools)
- `'tool_based'`: Place marker on tool schema (when MCP tools are rendered)
- `'none'`: Global cache disabled

### 2.5 Sticky-On Beta Latches

Once activated during a session, maintained until session end (to prevent cache invalidation):

```typescript
// Latch state (stored in bootstrap state)
afkModeHeaderLatched: boolean      // AFK mode (auto mode)
fastModeHeaderLatched: boolean     // Fast mode
cacheEditingHeaderLatched: boolean // Cache editing (cached microcompact)
thinkingClearLatched: boolean      // Thinking clear (on cache miss after 1 hour)

// Latch rule: once true → maintained until /clear or /compact
// Per-call gates are maintained (isAgenticQuery, etc.)
```

### 2.6 Thinking Configuration

```typescript
// Per-model thinking strategy determination
if (modelSupportsAdaptiveThinking(model)) {
  thinking = { type: 'adaptive' }       // Adaptive thinking (no budget)
} else if (modelSupportsThinking(model)) {
  thinking = {
    type: 'enabled',
    budget_tokens: Math.min(maxOutput - 1, thinkingBudget)
  }
}
// temperature is only sent when thinking is disabled (API forces 1 when active)
```

### 2.7 Streaming Response Parsing

```typescript
// SSE event handler chain
for await (const part of stream) {
  switch (part.type) {
    case 'message_start':
      // Usage initialization, research metadata capture
    case 'content_block_start':
      // Per-block-type initialization: tool_use, server_tool_use, text, thinking
    case 'content_block_delta':
      // Incremental accumulation: text_delta, input_json_delta, thinking_delta
      // ConnectorText support (feature flag)
    case 'content_block_stop':
      // JSON parsing (tool_use input), signature verification preparation
    case 'message_delta':
      // stop_reason, usage accumulation
    case 'message_stop':
      // Final processing
  }
}
```

**Stream idle watchdog**:
```typescript
const STREAM_IDLE_TIMEOUT_MS = 90_000  // Default 90 seconds
const STREAM_IDLE_WARNING_MS = 45_000  // Warning at 45 seconds

// Timer reset on each chunk received
// Warning → log entry
// Timeout → stream abort + releaseStreamResources()
```

### 2.8 Non-Streaming Fallback

Automatic fallback to non-streaming request on streaming failure:

```typescript
function getNonstreamingFallbackTimeoutMs(): number {
  const override = parseInt(process.env.API_TIMEOUT_MS || '', 10)
  if (override) return override
  return isEnvTruthy(process.env.CLAUDE_CODE_REMOTE)
    ? 120_000   // CCR: timeout before container idle-kill
    : 300_000   // Normal: 5 minutes
}

const MAX_NON_STREAMING_TOKENS = /* reduced output tokens */
```

### 2.9 API Request/Response Schema

```typescript
// Final API request parameters (returned by paramsFromContext)
interface APIRequestParams {
  model: string                              // Normalized model string
  messages: MessageParam[]                   // Including cache breakpoints
  system: TextBlockParam[]                   // System prompt blocks
  tools: BetaToolUnion[]                     // Tools + advisor + extra schemas
  tool_choice?: BetaToolChoiceTool | Auto
  betas?: string[]                           // Dynamically composed beta headers
  metadata: { user_id: string }              // Device/session info JSON
  max_tokens: number
  thinking?: { type: 'adaptive' } | { type: 'enabled', budget_tokens: number }
  temperature?: number                       // Only when thinking is disabled
  context_management?: object                // API context management strategy
  output_config?: {
    effort?: string                          // Effort level
    task_budget?: { type: 'tokens', total: number, remaining?: number }
    format?: BetaJSONOutputFormat            // Structured output
  }
  speed?: 'fast'                             // Fast mode
  stream: true                               // Streaming enabled
}
```

---

## 3. Error Handling

> Source: `src/services/api/errors.ts` (1,207 lines)

### 3.1 Error Classification Hierarchy

```
┌─────────────────────────────────────────────────────────┐
│                 classifyAPIError()                        │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  Retryable (handled by withRetry)                          │
│  ├── server_overload (529)                               │
│  ├── rate_limit (429)                                    │
│  └── api_timeout (connection timeout)                      │
│                                                          │
│  Permanent errors (shown to user)                          │
│  ├── authentication_failed (401/403)                     │
│  ├── invalid_request (400)                               │
│  ├── prompt_too_long (400/413)                           │
│  ├── credit_balance_low                                  │
│  ├── invalid_model                                       │
│  └── billing_error                                       │
│                                                          │
│  Media-related                                             │
│  ├── pdf_too_large                                       │
│  ├── pdf_password_protected                              │
│  ├── image_too_large                                     │
│  └── image_too_large (many-image dimension)              │
│                                                          │
│  Tool-related                                              │
│  ├── tool_use_mismatch                                   │
│  ├── unexpected_tool_result                              │
│  └── duplicate_tool_use_id                               │
│                                                          │
│  Special states                                            │
│  ├── repeated_529                                        │
│  ├── capacity_off_switch (Opus capacity emergency cutoff)   │
│  └── aborted (user cancellation)                           │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

### 3.2 User-Facing Error Message Mapping

```typescript
// Key constant messages
const ERROR_MESSAGES = {
  CREDIT_BALANCE_TOO_LOW:       'Credit balance is too low',
  INVALID_API_KEY:              'Not logged in · Please run /login',
  INVALID_API_KEY_EXTERNAL:     'Invalid API key · Fix external API key',
  ORG_DISABLED_ENV_KEY_OAUTH:   'ANTHROPIC_API_KEY belongs to disabled org · Unset to use subscription',
  TOKEN_REVOKED:                'OAuth token revoked · Please run /login',
  CCR_AUTH:                     'Authentication error · temporary network issue, try again',
  REPEATED_529:                 'Repeated 529 Overloaded errors',
  CUSTOM_OFF_SWITCH:            'Opus experiencing high load, use /model to switch to Sonnet',
  API_TIMEOUT:                  'Request timed out',
}

// Different messages used in non-interactive (SDK) mode
function getTokenRevokedErrorMessage(): string {
  return getIsNonInteractiveSession()
    ? 'Account does not have access. Please login again.'
    : TOKEN_REVOKED_ERROR_MESSAGE
}
```

### 3.3 Prompt-Too-Long Handling

```typescript
// Token count parsing: "prompt is too long: 137500 tokens > 135000 maximum"
function parsePromptTooLongTokenCounts(raw: string): {
  actualTokens: number | undefined
  limitTokens: number | undefined
}

// Excess token gap calculation (used in reactive compact)
function getPromptTooLongTokenGap(msg: AssistantMessage): number | undefined {
  // Returns gap if actualTokens - limitTokens > 0
  // compact uses this gap to skip multiple groups at once
}
```

### 3.4 REPEATED_529 Handling

Escalation when 529 errors occur consecutively in `withRetry.ts`:

```typescript
// withRetry internal state
let consecutive529Errors = initialConsecutive529Errors ?? 0

// On 529 detection
if (is529Error(error)) {
  consecutive529Errors++
  if (consecutive529Errors >= MAX_CONSECUTIVE_529) {
    throw new CannotRetryError(REPEATED_529_ERROR_MESSAGE)
  }
  // Exponential backoff retry
}
```

### 3.5 429 Rate Limit Detailed Handling

```typescript
// Refined classification based on new API headers
type RateLimitType = 'five_hour' | 'seven_day' | 'seven_day_opus'
type OverageStatus = 'allowed' | 'allowed_warning' | 'rejected'

// Extracted from headers
'anthropic-ratelimit-unified-representative-claim'  // Limit type
'anthropic-ratelimit-unified-overage-status'        // Overage status
'anthropic-ratelimit-unified-reset'                 // Reset timestamp
'anthropic-ratelimit-unified-overage-reset'         // Overage reset
'anthropic-ratelimit-unified-overage-disabled-reason' // Overage disabled reason

// Returns NO_RESPONSE_REQUESTED if overage is not 'rejected'
// → Triggers automatic fallback (Opus → Sonnet)
```

### 3.6 Media Size Error Detection

```typescript
function isMediaSizeError(raw: string): boolean {
  return (
    (raw.includes('image exceeds') && raw.includes('maximum')) ||
    (raw.includes('image dimensions exceed') && raw.includes('many-image')) ||
    /maximum of \d+ PDF pages/.test(raw)
  )
}
// In reactive compact retry: if media error, stripImages → retry
// Otherwise bail
```

### 3.7 3P Model Fallback Suggestion

```typescript
function get3PModelFallbackSuggestion(model: string): string | undefined {
  // opus-4-6 family → suggest opus41
  // sonnet-4-6 family → suggest sonnet45
  // sonnet-4-5 family → suggest sonnet40
  // 1P users: no suggestion (undefined)
}
```

---

## 4. Analytics System

> Source: `src/services/analytics/`

### 4.1 Architecture Overview

```
┌────────────────────────────────────────────────────────────────┐
│                     logEvent(name, metadata)                    │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  ┌─────────────┐    ┌──────────────┐    ┌─────────────────┐   │
│  │  GrowthBook  │    │  1P Logger   │    │    DataDog      │   │
│  │  (Feature    │    │  (OTel +     │    │  (Log Batch)    │   │
│  │   Flags &    │    │   Batch      │    │                 │   │
│  │   Experiments│    │   Export)    │    │                 │   │
│  └─────────────┘    └──────────────┘    └─────────────────┘   │
│         │                  │                     │             │
│    Remote Eval        /api/event_logging    Logs API v2        │
│    (Server-side)        /batch              (HTTP Intake)      │
│                                                                │
│  ┌────────────────────────────────────────────────────┐       │
│  │              PII Sanitization Layer                  │       │
│  │  - MCP toolName → 'mcp_tool'                          │       │
│  │  - File path removal                                    │       │
│  │  - AnalyticsMetadata_I_VERIFIED_... type enforcement      │       │
│  └────────────────────────────────────────────────────┘       │
└────────────────────────────────────────────────────────────────┘
```

### 4.2 GrowthBook Integration

> Source: `src/services/analytics/growthbook.ts` (1,155 lines)

```typescript
// User attributes (for targeting)
interface GrowthBookUserAttributes {
  id: string                        // Device ID
  sessionId: string
  deviceID: string
  platform: 'win32' | 'darwin' | 'linux'
  apiBaseUrlHost?: string
  organizationUUID?: string
  accountUUID?: string
  userType?: string                 // 'ant' | undefined
  subscriptionType?: string         // 'pro' | 'max' | 'team_premium'
  rateLimitTier?: string
  firstTokenTime?: number
  email?: string
  appVersion?: string
  github?: GitHubActionsMetadata
}
```

**Key functions**:

```typescript
// Synchronous lookup (from cache, may be stale)
function getFeatureValue_CACHED_MAY_BE_STALE<T>(key: string, defaultValue: T): T

// Lookup after initialization wait (may block)
async function getDynamicConfig_BLOCKS_ON_INIT<T>(key: string, defaultValue: T): T

// Environment variable override (ant only)
// CLAUDE_INTERNAL_FC_OVERRIDES='{"feature": true}'
function hasGrowthBookEnvOverride(feature: string): boolean
```

**Remote eval mode**:
- Feature flag evaluation on server side instead of SDK
- Cached in `remoteEvalFeatureValues` Map
- Disk cache (GrowthBook default) + in-session memory cache

**Experiment exposure logging**:
```typescript
// Exposure tracking (dedup)
const loggedExposures = new Set<string>()
const pendingExposures = new Set<string>()  // Pre-init access

// Experiment data storage
type StoredExperimentData = {
  experimentId: string
  variationId: number
  inExperiment?: boolean
  hashAttribute?: string
  hashValue?: string
}
```

**Refresh signal**:
```typescript
// Notify subscribers when GrowthBook values are refreshed
function onGrowthBookRefresh(listener: () => void): () => void
// catch-up: if already initialized, invoke immediately on next microtask
```

### 4.3 1st Party Event Logger

> Source: `src/services/analytics/firstPartyEventLogger.ts` (449 lines)

OpenTelemetry-based batch event logging:

```typescript
// Batch configuration (dynamically fetched from GrowthBook)
type BatchConfig = {
  scheduledDelayMillis?: number    // Batch send interval
  maxExportBatchSize?: number      // Max events per batch
  maxQueueSize?: number            // Max queue size
  skipAuth?: boolean               // Skip authentication
  maxAttempts?: number             // Max retry attempts
  path?: string                    // Custom path
  baseUrl?: string                 // Custom base URL
}

// GrowthBook config key
const BATCH_CONFIG_NAME = 'tengu_1p_event_batch_config'
```

**Event structure**:
```typescript
{
  event_name: string,
  event_id: UUID,
  core_metadata: EnvironmentMetadata,    // Model, session, environment info
  user_metadata: CoreUserData,           // User data (PII filtered)
  event_metadata: Record<string, number | boolean>,  // Per-event metadata
  user_id: string,                       // Device ID
}
```

**Reinitialization on GrowthBook refresh**:
```typescript
// Batch config change detection → LoggerProvider recreation
onGrowthBookRefresh(() => {
  reinitialize1PEventLoggingIfConfigChanged()
})
```

### 4.4 Event Sampling

```typescript
// Fetch sampling config from GrowthBook
const EVENT_SAMPLING_CONFIG_NAME = 'tengu_event_sampling_config'

type EventSamplingConfig = {
  [eventName: string]: {
    sample_rate: number  // Range 0-1
  }
}

function shouldSampleEvent(eventName: string): number | null {
  // No config → 100% (return null)
  // rate >= 1 → 100% (return null)
  // rate <= 0 → 0% (return 0 = drop)
  // 0 < rate < 1 → Math.random() < rate ? rate : 0
}
```

### 4.5 DataDog Logging

> Source: `src/services/analytics/datadog.ts`

```typescript
// Configuration
const DATADOG_LOGS_ENDPOINT = 'https://http-intake.logs.us5.datadoghq.com/api/v2/logs'
const DEFAULT_FLUSH_INTERVAL_MS = 15000
const MAX_BATCH_SIZE = 100
const NETWORK_TIMEOUT_MS = 5000

// Allowed events whitelist (44)
const DATADOG_ALLOWED_EVENTS = new Set([
  // Chrome Bridge (7)
  'chrome_bridge_connection_succeeded', 'chrome_bridge_connection_failed',
  'chrome_bridge_disconnected', 'chrome_bridge_tool_call_completed',
  'chrome_bridge_tool_call_error', 'chrome_bridge_tool_call_started',
  'chrome_bridge_tool_call_timeout',
  // Tengu Core (11)
  'tengu_api_error', 'tengu_api_success', 'tengu_brief_mode_enabled',
  'tengu_brief_mode_toggled', 'tengu_brief_send', 'tengu_cancel',
  'tengu_compact_failed', 'tengu_exit', 'tengu_flicker', 'tengu_init',
  'tengu_model_fallback_triggered',
  // Tengu OAuth (10)
  'tengu_oauth_error', 'tengu_oauth_success',
  'tengu_oauth_token_refresh_failure', 'tengu_oauth_token_refresh_success',
  'tengu_oauth_token_refresh_lock_acquiring', 'tengu_oauth_token_refresh_lock_acquired',
  'tengu_oauth_token_refresh_starting', 'tengu_oauth_token_refresh_completed',
  'tengu_oauth_token_refresh_lock_releasing', 'tengu_oauth_token_refresh_lock_released',
  // Tengu Tools/Session (12)
  'tengu_query_error', 'tengu_session_file_read', 'tengu_started',
  'tengu_tool_use_error', 'tengu_tool_use_granted_in_prompt_permanent',
  'tengu_tool_use_granted_in_prompt_temporary', 'tengu_tool_use_rejected_in_prompt',
  'tengu_tool_use_success', 'tengu_uncaught_exception', 'tengu_unhandled_rejection',
  'tengu_voice_recording_started', 'tengu_voice_toggled',
  // Team Memory (4)
  'tengu_team_mem_sync_pull', 'tengu_team_mem_sync_push',
  'tengu_team_mem_sync_started', 'tengu_team_mem_entries_capped',
])

// Tag fields (for Datadog indexing, 16)
const TAG_FIELDS = [
  'arch', 'clientType', 'errorType', 'http_status_range', 'http_status',
  'kairosActive', 'model', 'platform', 'provider', 'skillMode',
  'subscriptionType', 'toolName', 'userBucket', 'userType',
  'version', 'versionBase',
]
```

### 4.6 PII-Protected Metadata

> Source: `src/services/analytics/metadata.ts` (973 lines)

```typescript
// Type enforcement: cast string to never type to indicate intentional verification
type AnalyticsMetadata_I_VERIFIED_THIS_IS_NOT_CODE_OR_FILEPATHS = never

// MCP toolName sanitization
function sanitizeToolNameForAnalytics(toolName: string): never {
  if (toolName.startsWith('mcp__')) return 'mcp_tool' as never
  return toolName as never
}

// Conditions for allowing MCP detailed logging
function isAnalyticsToolDetailsLoggingEnabled(
  mcpServerType: string | undefined,
  mcpServerBaseUrl: string | undefined,
): boolean {
  // local-agent (Cowork) → Always allowed
  // claudeai-proxy → Always allowed
  // Official MCP registry URLs → allowed
  // Others → not allowed (sanitize)
}
```

**Gateway detection** (`logging.ts`):

```typescript
// Auto-detect AI gateways from response headers
type KnownGateway = 'litellm' | 'helicone' | 'portkey' |
  'cloudflare-ai-gateway' | 'kong' | 'braintrust' | 'databricks'

const GATEWAY_FINGERPRINTS = {
  litellm:    { prefixes: ['x-litellm-'] },
  helicone:   { prefixes: ['helicone-'] },
  portkey:    { prefixes: ['x-portkey-'] },
  // ...
}
```

### 4.7 Analytics Event Classification

| Category | Event Pattern | Description |
|---------|-----------|------|
| API | `tengu_api_query`, `tengu_api_success`, `tengu_api_error` | API call lifecycle |
| Tools | `tengu_tool_use_success`, `tengu_tool_use_error` | Tool execution |
| Session | `tengu_init`, `tengu_started`, `tengu_exit` | Session lifecycle |
| OAuth | `tengu_oauth_success`, `tengu_oauth_error`, `tengu_oauth_token_refresh_*` | Authentication |
| Compact | `tengu_compact_failed` | Context compression |
| Cache | `tengu_cache_break_*` | Prompt cache |
| Model | `tengu_model_fallback_triggered` | Model switch |
| Streaming | `tengu_streaming_stall`, `tengu_streaming_idle_timeout` | Stream anomaly |
| Migration | `tengu_opus_to_opus1m_migration`, `tengu_sonnet45_to_46_migration` | Settings migration |

---

## 5. Context Compression

### 5.1 Three Compression Strategies

```
┌──────────────────────────────────────────────────────────┐
│                  Context Compression                      │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────────────┐ │
│  │   compact    │  │ microCompact │  │  autoCompact    │ │
│  │  (1,705 lines)│  │  (530 lines) │  │  (proactive)    │ │
│  ├─────────────┤  ├──────────────┤  ├─────────────────┤ │
│  │ Full summary │  │ Inline       │  │ Auto-trigger    │ │
│  │ - LLM call  │  │  shrinking   │  │ - Token         │ │
│  │ - Boundary  │  │ - Tool result│  │   threshold     │ │
│  │   markers   │  │   truncation │  │ - Time-based    │ │
│  │ - File      │  │ - Image      │  │ - Reactive PTL  │ │
│  │   restore   │  │   removal    │  │                 │ │
│  └─────────────┘  └──────────────┘  └─────────────────┘ │
│                                                          │
│  ┌──────────────────────────────────────────────────┐   │
│  │  cached microcompact (cache_edits)               │   │
│  │  - Delete tool results via server-side cache edits │   │
│  │  - Reduce context while maintaining cache hit rate │   │
│  └──────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────┘
```

### 5.2 Full Compact (compact.ts)

> Source: `src/services/compact/compact.ts` (1,705 lines)

```typescript
interface CompactionResult {
  boundaryMarker: SystemMessage           // Compaction boundary marker
  summaryMessages: UserMessage[]          // LLM-generated summary
  attachments: AttachmentMessage[]        // Attachments to be reinjected
  hookResults: HookResultMessage[]        // Hook results
  messagesToKeep?: Message[]              // Messages to keep (suffix)
  userDisplayMessage?: string             // User display message
  preCompactTokenCount?: number
  postCompactTokenCount?: number
  truePostCompactTokenCount?: number
  compactionUsage?: TokenUsage
}

async function compactConversation(
  messages: Message[],
  context: ToolUseContext,
  cacheSafeParams: CacheSafeParams,
  suppressFollowUpQuestions: boolean,
  customInstructions?: string,
  isAutoCompact?: boolean,
  recompactionInfo?: RecompactionInfo,
): Promise<CompactionResult>
```

**Compaction preprocessing**:
```typescript
// 1. Strip image/document blocks (unnecessary for summary, prevents PTL)
stripImagesFromMessages(messages)

// 2. Strip skills/attachments (will be reinjected)
stripReinjectedAttachments(messages)

// 3. PTL retry: delete from oldest groups first
truncateHeadForPTLRetry(messages, ptlResponse)
// → Based on token gap or 20% fallback
```

**Post-processing constants**:
```typescript
const POST_COMPACT_MAX_FILES_TO_RESTORE = 5     // Max files to restore
const POST_COMPACT_TOKEN_BUDGET = 50_000         // Total budget for file restoration
const POST_COMPACT_MAX_TOKENS_PER_FILE = 5_000   // Max tokens per file
const POST_COMPACT_MAX_TOKENS_PER_SKILL = 5_000  // Max tokens per skill
const POST_COMPACT_SKILLS_TOKEN_BUDGET = 25_000  // Total skill budget
const MAX_COMPACT_STREAMING_RETRIES = 2          // Streaming retries
```

### 5.3 Micro Compact (microCompact.ts)

> Source: `src/services/compact/microCompact.ts` (530 lines)

Inline shrinking of tool results (without LLM calls):

```typescript
// Tools eligible for compaction
const COMPACTABLE_TOOLS = new Set([
  'Read', 'Bash', 'Grep', 'Glob',
  'WebSearch', 'WebFetch',
  'Edit', 'Write',
])

// Tool result token calculation
function calculateToolResultTokens(block: ToolResultBlockParam): number {
  // Text: roughTokenCountEstimation
  // Image/document: fixed 2000 tokens
}

// Message token estimation
function estimateMessageTokens(messages: Message[]): number {
  // text, tool_result, image, document, thinking,
  // redacted_thinking, tool_use each processed
  // × 4/3 conservative padding
}
```

**Time-based MicroCompact**:
```typescript
type TimeBasedMCConfig = {
  enabled: boolean
  maxAgeMs: number           // Maximum age (milliseconds)
  minTokens: number          // Minimum token count (skip if below)
  // ...
}

const TIME_BASED_MC_CLEARED_MESSAGE = '[Old tool result content cleared]'
```

### 5.4 Cached Microcompact (cache_edits)

```typescript
// State management
interface CachedMCState {
  pinnedEdits: PinnedCacheEdits[]  // Previously sent edits (position pinned)
  // ...
}

// Consume pending cache edits (one-time)
function consumePendingCacheEdits(): CacheEditsBlock | null
// → Insert as cache_edits block in API request
// → Server deletes that portion from cached content
// → Saves tokens while maintaining cache hits

// Re-send pinned edits
function getPinnedCacheEdits(): PinnedCacheEdits[]
// → Re-send previously inserted edits at the same position

// Mark tools as sent-to-API state
function markToolsSentToAPIState(): void
```

### 5.5 Auto Compact (autoCompact.ts)

```typescript
// Threshold constants
const AUTOCOMPACT_BUFFER_TOKENS = 13_000
const WARNING_THRESHOLD_BUFFER_TOKENS = 20_000
const ERROR_THRESHOLD_BUFFER_TOKENS = 20_000
const MANUAL_COMPACT_BUFFER_TOKENS = 3_000
const MAX_CONSECUTIVE_AUTOCOMPACT_FAILURES = 3    // Circuit breaker

// Effective context window size
function getEffectiveContextWindowSize(model: string): number {
  const reserved = Math.min(getMaxOutputTokensForModel(model), 20_000)
  let contextWindow = getContextWindowForModel(model, sdkBetas)
  // CLAUDE_CODE_AUTO_COMPACT_WINDOW override support
  return contextWindow - reserved
}

// Auto-compact threshold
function getAutoCompactThreshold(model: string): number {
  return getEffectiveContextWindowSize(model) - AUTOCOMPACT_BUFFER_TOKENS
  // CLAUDE_AUTOCOMPACT_PCT_OVERRIDE: percent-based override
}

// Token warning state calculation
interface TokenWarningState {
  percentLeft: number
  isAboveWarningThreshold: boolean
  isAboveErrorThreshold: boolean
  isAboveAutoCompactThreshold: boolean
  isAtBlockingLimit: boolean
}
```

**Disabled conditions**:
```typescript
function isAutoCompactEnabled(): boolean {
  if (isEnvTruthy(process.env.DISABLE_COMPACT)) return false
  if (isEnvTruthy(process.env.DISABLE_AUTO_COMPACT)) return false
  return getGlobalConfig().autoCompactEnabled
}

// Sources excluded from shouldAutoCompact
// - 'session_memory': forked agent (deadlock prevention)
// - 'compact': recursion prevention
// - 'marble_origami': context agent (module state sharing issue)
```

---

## 6. OAuth System

> Source: `src/services/oauth/client.ts`

### 6.1 PKCE flow

```
User → CLI → Browser
  │          │
  │  1. codeVerifier = random()
  │  2. codeChallenge = SHA256(codeVerifier)
  │          │
  │          ├── buildAuthUrl() ──────────────────────► Claude AI / Console
  │          │   - code_challenge (S256)                   Login Page
  │          │   - redirect_uri (localhost:PORT/callback)
  │          │   - scope: oauth_scopes
  │          │   - state: random
  │          │   - orgUUID (optional)
  │          │   - login_hint (email, optional)
  │          │   - login_method (sso/magic_link, optional)
  │          │
  │          ◄── callback?code=AUTH_CODE&state=STATE ◄──
  │          │
  │  3. exchangeCodeForTokens()
  │          │   - grant_type: authorization_code
  │          │   - code: AUTH_CODE
  │          │   - code_verifier: codeVerifier
  │          │   - client_id: CLIENT_ID
  │          │
  │          ├── POST /oauth/token ────────────────────► Token Endpoint
  │          │
  │          ◄── { access_token, refresh_token,
  │               expires_in, scope }
  │          │
  │  4. Token storage (secure storage + global config)
  │
```

### 6.2 Token Refresh

```typescript
async function refreshOAuthToken(
  refreshToken: string,
  { scopes }: { scopes?: string[] } = {},
): Promise<OAuthTokens> {
  const requestBody = {
    grant_type: 'refresh_token',
    refresh_token: refreshToken,
    client_id: getOauthConfig().CLIENT_ID,
    scope: (scopes || CLAUDE_AI_OAUTH_SCOPES).join(' '),
  }

  // 7M req/day optimization: skip /api/oauth/profile if existing profile data available
  const config = getGlobalConfig()
  // Skip profile fetch if subscription info exists in both config + secure storage
}
```

### 6.3 Scope Management

```typescript
// Scope types
const CLAUDE_AI_INFERENCE_SCOPE = /* Claude AI inference only */
const CLAUDE_AI_OAUTH_SCOPES    = /* Default OAuth scope set */
const ALL_OAUTH_SCOPES          = /* All scopes (including profile) */

// Inference-only login (long-lived token)
function buildAuthUrl({ inferenceOnly: true }) {
  // Request only scope = [CLAUDE_AI_INFERENCE_SCOPE]
}

// Scope check
function shouldUseClaudeAIAuth(scopes): boolean {
  return scopes?.includes(CLAUDE_AI_INFERENCE_SCOPE)
}

function hasProfileScope(): boolean {
  // Whether profile info access is available
}
```

### 6.4 Profile Lookup

```typescript
// OAuth profile response
interface OAuthProfileResponse {
  account_uuid: string
  organization_uuid: string
  subscription_type: SubscriptionType  // 'pro' | 'max' | 'team' | ...
  billing_type: BillingType
  rate_limit_tier: RateLimitTier
  // ...
}

// Role lookup
interface UserRolesResponse {
  // User roles within organization
}
```

---

## 7. Policy & Settings

### 7.1 Policy Limits

> Source: `src/services/policyLimits/`

Fetch organization-level policy limits from API to disable CLI features:

```typescript
// Response schema
const PolicyLimitsResponseSchema = z.object({
  restrictions: z.record(z.string(), z.object({ allowed: z.boolean() })),
})

// Fetch result
type PolicyLimitsFetchResult = {
  success: boolean
  restrictions?: PolicyLimitsResponse['restrictions'] | null  // null = 304
  etag?: string
  error?: string
  skipRetry?: boolean
}
```

**Operational characteristics**:
| Characteristic | Value |
|------|-----|
| Cache file | `~/.claude/policy-limits.json` |
| Fetch Timeout | 10s |
| Max retries | 5 |
| Polling interval | 1 hour |
| Failure policy | Fail-open (non-blocking) |
| ETag caching | Checksum-based (`sha256:` prefix) |
| Loading timeout | 30s (deadlock prevention) |

**Eligibility determination**:
```typescript
function isPolicyLimitsEligible(): boolean {
  // 3P provider → false
  // Custom base URL → false
  // Console (API key) → true
  // OAuth (Claude.ai):
  //   - Team/Enterprise subscribers → true
  //   - Others → false
}
```

### 7.2 Remote Managed Settings

> Source: `src/services/remoteManagedSettings/`

Remote managed settings for enterprise customers:

```typescript
const RemoteManagedSettingsResponseSchema = z.object({
  uuid: z.string(),
  checksum: z.string(),
  settings: z.record(z.string(), z.unknown()) as z.ZodType<SettingsJson>,
})

type RemoteManagedSettingsFetchResult = {
  success: boolean
  settings?: SettingsJson | null  // null = 304 Not Modified
  checksum?: string
  error?: string
  skipRetry?: boolean
}
```

**3-tier settings configuration**:

```
┌───────────────────────────────────────────────┐
│  Priority (high → low)                             │
│                                               │
│  1. policySettings    ← Policy Limits API     │
│  2. localSettings     ← .claude/settings.local│
│  3. projectSettings   ← .claude/settings.json │
│  4. flagSettings      ← CLI --flag or inline       │
│  5. userSettings      ← ~/.claude/settings.json│
│  + remoteManagedSettings (separate merge)           │
│                                               │
│  Active sources determined by State.allowedSettingSources │
└───────────────────────────────────────────────┘
```

---

## 8. Token Estimation

> Source: `src/services/tokenEstimation.ts`

### 8.1 API-Based Token Counting

```typescript
// Count tokens of messages + tools
async function countMessagesTokensWithAPI(
  messages: BetaMessageParam[],
  tools: BetaToolUnion[],
): Promise<number | null> {
  // 1. VCR wrapping (for test replay)
  // 2. Per-provider branching:
  //    - Bedrock: countTokensWithBedrock() (separate SDK)
  //    - Vertex: countTokens after filtering allowed betas
  //    - 1P: anthropic.beta.messages.countTokens()
  // 3. Add thinking config when thinking blocks are present
  // 4. Return null on failure (graceful degradation)
}
```

### 8.2 Bedrock-Specific Token Counting

```typescript
async function countTokensWithBedrock(params: {
  model: string
  messages: BetaMessageParam[]
  tools: BetaToolUnion[]
  betas: string[]
  containsThinking: boolean
}): Promise<number | null> {
  // Dynamic import of @aws-sdk/client-bedrock-runtime (279KB deferred)
  // Uses CountTokensCommand
  // Inference profile → Foundation model conversion
}
```

### 8.3 Rough Estimation (Fallback)

```typescript
// Character-count-based token estimation (4/3 padding)
function roughTokenCountEstimation(text: string): number {
  return Math.ceil(text.length / 3)  // ~3 chars/token + conservative padding
}

// Rough token estimation for message arrays
function roughTokenCountEstimationForMessages(messages: Message[]): number
```

### 8.4 Tool Search Field Cleanup

```typescript
// Strip tool-search-specific fields before token counting
// (error if sent without tool search beta)
function stripToolSearchFieldsFromMessages(messages): messages {
  // Remove 'caller' field from tool_use blocks
  // Filter tool_reference blocks within tool_result
  // Empty content → replace with '[tool references]'
}
```

---

## 9. Migration System

> Source: `src/migrations/` (11 files)

### 9.1 Migration Chain Diagram

```
                    ┌─ Model Migrations ──────────────────────────────────────┐
                    │                                                          │
fennec-latest ──► opus ──► opus[1m]     (migrateFennecToOpus)                  │
fennec-latest[1m] ─► opus[1m]          (migrateFennecToOpus)                   │
fennec-fast-latest ─► opus[1m]+fast    (migrateFennecToOpus)                   │
opus-4-5-fast ──────► opus+fast        (migrateFennecToOpus)                   │
opus ──────────────► opus[1m]          (migrateOpusToOpus1m, Max/Team only)     │
                    │                                                          │
sonnet[1m] ────────► sonnet-4-5[1m]    (migrateSonnet1mToSonnet45, implicit)    │
sonnet-4-5-* ──────► sonnet / sonnet[1m] (migrateSonnet45ToSonnet46)           │
                    │                                                          │
                    │                                                          │
                    │  migrateLegacyOpusToCurrent (1P/ant only, DCE)           │
                    │  → Legacy Opus strings ('claude-opus-4-20250514',        │
                    │    'claude-opus-4-1-20250805', 'claude-opus-4-0',       │
                    │    'claude-opus-4-1') → migrate to 'opus' alias          │
                    │                                                          │
                    └──────────────────────────────────────────────────────────┘

                    ┌─ Settings Migrations ───────────────────────────────────┐
                    │                                                          │
                    │  migrateAutoUpdatesToSettings                            │
                    │  → Move auto-update settings to settings.json            │
                    │                                                          │
                    │  migrateBypassPermissionsAcceptedToSettings              │
                    │  → Move permission bypass settings                       │
                    │                                                          │
                    │  migrateEnableAllProjectMcpServersToSettings             │
                    │  → Move MCP server activation settings                   │
                    │                                                          │
                    │  migrateReplBridgeEnabledToRemoteControlAtStartup        │
                    │  → Move REPL bridge → remote control settings            │
                    │                                                          │
                    │  resetAutoModeOptInForDefaultOffer                       │
                    │  → Reset auto mode opt-in                                │
                    │                                                          │
                    │  resetProToOpusDefault                                    │
                    │  → Reset Pro subscriber Opus default                     │
                    │                                                          │
                    └──────────────────────────────────────────────────────────┘
```

### 9.2 Migration Execution Pattern

```typescript
// All migrations follow the same pattern:
function migrateSomething(): void {
  // 1. Eligibility check (subscription type, provider, ant status)
  if (!isEligible()) return

  // 2. Read current settings (userSettings source only)
  const model = getSettingsForSource('userSettings')?.model
  if (!needsMigration(model)) return

  // 3. Update settings
  updateSettingsForSource('userSettings', { model: newModel })

  // 4. Analytics event logging
  logEvent('tengu_xxx_migration', { from_model, to_model })

  // 5. Notification flag (optional)
  saveGlobalConfig(current => ({
    ...current,
    migrationTimestamp: Date.now(),
  }))
}
```

### 9.3 Fennec → Opus Migration Detail

```typescript
// ant-only migration (fennec is internal codename)
function migrateFennecToOpus(): void {
  if (process.env.USER_TYPE !== 'ant') return

  const mappings = {
    'fennec-latest[1m]':     'opus[1m]',
    'fennec-latest':          'opus',
    'fennec-fast-latest':     'opus[1m]' + fastMode,
    'opus-4-5-fast':          'opus[1m]' + fastMode,
  }
}
```

### 9.4 Sonnet 4.5 → 4.6 Migration Detail

```typescript
function migrateSonnet45ToSonnet46(): void {
  // Condition: 1P + (Pro OR Max OR TeamPremium)
  // Target model strings:
  //   'claude-sonnet-4-5-20250929'      → 'sonnet'
  //   'claude-sonnet-4-5-20250929[1m]'  → 'sonnet[1m]'
  //   'sonnet-4-5-20250929'             → 'sonnet'
  //   'sonnet-4-5-20250929[1m]'         → 'sonnet[1m]'

  // New users (numStartups <= 1) skip notification
  // Existing users: save sonnet45To46MigrationTimestamp
}
```

---

## 10. Bootstrap

> Source: `src/bootstrap/state.ts`

### 10.1 Global State Singleton

```typescript
type State = {
  // === Project/Path ===
  originalCwd: string          // Working directory at startup (symlink resolved)
  projectRoot: string          // Stable project root (for history, skills)
  cwd: string                  // Current working directory

  // === Cost/Performance Tracking ===
  totalCostUSD: number
  totalAPIDuration: number
  totalAPIDurationWithoutRetries: number
  totalToolDuration: number
  turnHookDurationMs: number
  turnToolDurationMs: number
  turnClassifierDurationMs: number
  turnToolCount: number
  turnHookCount: number
  turnClassifierCount: number
  totalLinesAdded: number
  totalLinesRemoved: number
  hasUnknownModelCost: boolean

  // === Session ===
  sessionId: SessionId           // randomUUID()
  parentSessionId: SessionId     // Session lineage tracking
  startTime: number
  lastInteractionTime: number
  isInteractive: boolean
  clientType: string             // 'cli' | 'sdk' | ...
  sessionSource: string          // Session origin

  // === Model ===
  modelUsage: { [modelName: string]: ModelUsage }
  mainLoopModelOverride: ModelSetting
  initialMainLoopModel: ModelSetting
  modelStrings: ModelStrings | null

  // === Telemetry ===
  meter: Meter | null
  sessionCounter: AttributedCounter | null
  locCounter: AttributedCounter | null
  prCounter: AttributedCounter | null
  commitCounter: AttributedCounter | null
  costCounter: AttributedCounter | null
  tokenCounter: AttributedCounter | null
  codeEditToolDecisionCounter: AttributedCounter | null
  activeTimeCounter: AttributedCounter | null
  statsStore: { observe(name: string, value: number): void } | null

  // === Logging ===
  loggerProvider: LoggerProvider | null
  eventLogger: ReturnType<typeof logs.getLogger> | null
  meterProvider: MeterProvider | null
  tracerProvider: BasicTracerProvider | null

  // === Cache/State ===
  lastAPIRequest: Omit<BetaMessageStreamParams, 'messages'> | null
  lastAPIRequestMessages: BetaMessageStreamParams['messages'] | null
  lastClassifierRequests: unknown[] | null
  cachedClaudeMdContent: string | null
  inMemoryErrorLog: Array<{ error: string; timestamp: string }>

  // === Prompt Cache Latches ===
  promptCache1hAllowlist: string[] | null
  promptCache1hEligible: boolean | null
  afkModeHeaderLatched: boolean | null
  fastModeHeaderLatched: boolean | null
  cacheEditingHeaderLatched: boolean | null
  thinkingClearLatched: boolean | null
  lastApiCompletionTimestamp: number | null
  lastMainRequestId: string | undefined
  pendingPostCompaction: boolean

  // === Plugins/Extensions ===
  inlinePlugins: Array<string>
  chromeFlagOverride: boolean | undefined
  useCoworkPlugins: boolean
  registeredHooks: Partial<Record<HookEvent, RegisteredHookMatcher[]>> | null
  allowedChannels: ChannelEntry[]

  // === Agent ===
  agentColorMap: Map<string, AgentColorName>
  agentColorIndex: number
  invokedSkills: Map<
    string,  // composite key: `${agentId ?? ''}:${skillName}` (prevents cross-agent overwrite)
    { skillName: string; skillPath: string; content: string; invokedAt: number; agentId: string | null }
  >
  sessionCreatedTeams: Set<string>   // Teams created via TeamCreate (auto-cleanup on shutdown)

  // === Settings/Permission ===
  flagSettingsPath: string | undefined
  flagSettingsInline: Record<string, unknown> | null
  allowedSettingSources: SettingSource[]
  sessionBypassPermissionsMode: boolean
  sessionTrustAccepted: boolean
  sessionPersistenceDisabled: boolean
  sdkBetas: string[] | undefined

  // === Auth Tokens (runtime only) ===
  sessionIngressToken: string | null | undefined  // Session ingress token
  oauthTokenFromFd: string | null | undefined     // FD-based OAuth token
  apiKeyFromFd: string | null | undefined         // FD-based API key

  // === Behavioral Flags ===
  kairosActive: boolean                            // KAIROS mode (proactive assistant)
  strictToolResultPairing: boolean                 // HFI: throw instead of repair on mismatch
  sdkAgentProgressSummariesEnabled: boolean        // SDK agent progress summaries enabled
  userMsgOptIn: boolean                            // User message collection consent
  questionPreviewFormat: 'markdown' | 'html' | undefined  // Question preview format

  // === Scheduler ===
  scheduledTasksEnabled: boolean                   // Cron scheduler enabled (not persisted)
  sessionCronTasks: SessionCronTask[]              // durable:false ephemeral cron tasks

  // === Plan/Auto Mode Tracking ===
  hasExitedPlanMode: boolean                       // For plan mode re-entry guidance
  needsPlanModeExitAttachment: boolean             // One-time plan mode exit notification
  needsAutoModeExitAttachment: boolean             // One-time auto mode exit notification

  // === Other Session State ===
  lspRecommendationShownThisSession: boolean       // LSP plugin recommendation shown (once)
  initJsonSchema: Record<string, unknown> | null   // jsonSchema for SDK init event
  planSlugCache: Map<string, string>               // sessionId → wordSlug cache
  teleportedSessionInfo: {
    isTeleported: boolean
    hasLoggedFirstMessage: boolean
    sessionId: string | null
  } | null
  slowOperations: Array<{                          // Slow operation tracking (ant-only display)
    operation: string
    durationMs: number
    timestamp: number
  }>
  mainThreadAgentType: string | undefined          // From --agent flag or settings
  isRemoteMode: boolean                            // --remote flag
  directConnectServerUrl: string | undefined       // Direct connect URL for header display
  systemPromptSectionCache: Map<string, string | null>  // System prompt section cache
  lastEmittedDate: string | null                   // Last date sent to model (for midnight detection)
  additionalDirectoriesForClaudeMd: string[]       // Additional directories from --add-dir flag
  hasDevChannels: boolean                          // Whether --dangerously-load-development-channels included
  sessionProjectDir: string | null                 // Session .jsonl directory (null = derived from originalCwd)
  promptId: string | null                          // Current prompt UUID (OTel event correlation)
}
```

### 10.2 Initial State

```typescript
function getInitialState(): State {
  // CWD: symlink resolution (realpathSync) + NFC normalization
  // EPERM fallback: use original when failed on CloudStorage mount

  return {
    sessionId: randomUUID() as SessionId,
    startTime: Date.now(),
    clientType: 'cli',
    allowedSettingSources: [
      'userSettings', 'projectSettings', 'localSettings',
      'flagSettings', 'policySettings',
    ],
    // ... (all remaining values are null/0/false/empty)
  }
}
```

### 10.3 Telemetry Meter Pattern

```typescript
type AttributedCounter = {
  add(value: number, additionalAttributes?: Attributes): void
}

// Usage pattern
STATE.costCounter?.add(costUSD, { model: 'opus-4.6' })
STATE.tokenCounter?.add(inputTokens, { type: 'input' })
STATE.locCounter?.add(linesAdded, { action: 'add' })
STATE.commitCounter?.add(1)
STATE.prCounter?.add(1)
```

---

## 11. CLI Layer

> Source: `src/cli/` (6 key files)

### 11.1 Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        CLI Layer                             │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌────────────┐  ┌────────────────┐  ┌──────────────────┐   │
│  │ structuredIO│  │   remoteIO     │  │   print.ts       │   │
│  │  (Base)     │  │   (extends)    │  │  (output format) │   │
│  ├────────────┤  ├────────────────┤  ├──────────────────┤   │
│  │ JSON parsing│  │ 3 Transports   │  │ Stream events    │   │
│  │ Control req │  │ - SSE          │  │ JSON/NDJSON      │   │
│  │ Permission  │  │ - WebSocket    │  │ Progress         │   │
│  └────────────┘  │ - Hybrid       │  └──────────────────┘   │
│                  └────────────────┘                          │
│                                                              │
│  ┌────────────┐  ┌────────────────┐  ┌──────────────────┐   │
│  │  exit.ts   │  │  update.ts     │  │ ndjsonSafe       │   │
│  │  Exit proc. │  │  Version update│  │ Stringify.ts     │   │
│  └────────────┘  └────────────────┘  └──────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 11.2 StructuredIO (Default I/O)

```typescript
class StructuredIO {
  readonly structuredInput: AsyncGenerator<StdinMessage | SDKMessage>
  readonly outbound: Stream<StdoutMessage>

  // Pending control requests (request ID → promise)
  private pendingRequests: Map<string, PendingRequest<unknown>>

  // Tool use resolution tracking (dedup, max 1000)
  private resolvedToolUseIds: Set<string>

  constructor(input: AsyncIterable<string>, replayUserMessages?: boolean)

  // Send control request (permission checks, etc.)
  async sendRequest<T>(request: SDKControlRequest, schema?: z.Schema): Promise<T>

  // Permission check
  async canUseTool(tool: Tool, input: Record<string, unknown>, toolUseID: string): Promise<PermissionDecision>

  // Emit events
  flushInternalEvents(): Promise<void>

  // Pre-input queueing
  prependLines(lines: string[]): void
}
```

### 11.3 RemoteIO (Remote I/O)

```typescript
class RemoteIO extends StructuredIO {
  private transport: Transport  // SSE | WebSocket | Hybrid
  private inputStream: PassThrough
  private ccrClient: CCRClient | null  // Claude Code Remote
  private keepAliveTimer: ReturnType<typeof setInterval> | null

  constructor(streamUrl: string, initialPrompt?, replayUserMessages?)

  // Transport layer selection
  // getTransportForUrl(url, headers, sessionId, refreshHeaders)

  // Dynamic header refresh (token refresh support)
  refreshHeaders(): Record<string, string>
}
```

### 11.4 Three Transport Layers

```typescript
// 1. SSE Transport
class SSETransport implements Transport {
  // Unidirectional streaming based on Server-Sent Events
  // Built-in reconnection logic
}

// 2. WebSocket Transport
// (URL protocol-based selection in TransportUtils)

// 3. Hybrid (CCR-specific)
class CCRClient {
  // Claude Code Remote dedicated client
  // Bidirectional communication + session management
}

// Transport selection logic
function getTransportForUrl(url, headers, sessionId, refreshHeaders): Transport {
  // ws:// / wss:// → WebSocket
  // http:// / https:// → SSE
  // CCR environment → CCR client
}
```

### 11.5 Control Protocol (SDK ↔ CLI)

```typescript
// Control request (CLI → SDK host)
type SDKControlRequest = {
  type: 'control_request'
  request: {
    id: string           // UUID
    subtype: 'can_use_tool' | 'elicit' | /* others */
    // Per-subtype payload
    tool_use_id?: string
    tool_name?: string
    input?: Record<string, unknown>
  }
}

// Control response (SDK host → CLI)
type SDKControlResponse = {
  type: 'control_response'
  response: {
    id: string           // Matches request ID
    // Per-subtype result
  }
}

// Virtual tool (for network permissions)
const SANDBOX_NETWORK_ACCESS_TOOL_NAME = 'SandboxNetworkAccess'
```

### 11.6 NDJSON Safe Serialization

```typescript
// ndjsonSafeStringify.ts
// Since newlines are record delimiters in NDJSON (Newline Delimited JSON),
// escape newlines within JSON strings
function ndjsonSafeStringify(obj: unknown): string
```

### 11.7 Exit Handling

```typescript
// exit.ts
// gracefulShutdown integration
// - Clean up in-progress streams
// - Flush telemetry
// - Shut down 1P event logger
// - Flush DataDog logs
// - Save session state
```

---

## Prompt Cache Break Detection

> Source: `src/services/api/promptCacheBreakDetection.ts`

### State Tracking

```typescript
type PreviousState = {
  systemHash: number           // System prompt hash
  toolsHash: number            // Tool schema hash
  cacheControlHash: number     // Hash including cache_control
  toolNames: string[]          // Tool name list
  perToolHashes: Record<string, number>  // Per-tool hash
  systemCharCount: number
  model: string
  fastMode: boolean
  globalCacheStrategy: string
  betas: string[]
  autoModeActive: boolean
  isUsingOverage: boolean
  cachedMCEnabled: boolean
  effortValue: string
  extraBodyHash: number
  callCount: number
  pendingChanges: PendingChanges | null
  prevCacheReadTokens: number | null
  cacheDeletionsPending: boolean
  buildDiffableContent: () => string
}
```

**Change detection items** (PendingChanges):
```typescript
{
  systemPromptChanged: boolean
  toolSchemasChanged: boolean    // Detailed tracking of which tools changed
  modelChanged: boolean
  fastModeChanged: boolean
  cacheControlChanged: boolean   // scope/TTL change
  globalCacheStrategyChanged: boolean
  betasChanged: boolean          // Added/removed beta list
  autoModeChanged: boolean
  overageChanged: boolean
  cachedMCChanged: boolean
  effortChanged: boolean
  extraBodyChanged: boolean
  addedTools: string[]
  removedTools: string[]
  changedToolSchemas: string[]   // Tool names with changed schemas
}
```

**Cache break determination criteria**:
```typescript
const MIN_CACHE_MISS_TOKENS = 2_000    // Minimum token reduction amount
const CACHE_TTL_5MIN_MS = 5 * 60 * 1000  // 5-minute TTL boundary
const CACHE_TTL_1HOUR_MS = 60 * 60 * 1000 // 1-hour TTL boundary
// Exclude haiku models (different caching behavior)
```

---

## Implementation Caveats

### C1. 401 Token Refresh Infinite Loop Risk
`withRetry()` retries after token refresh on 401 errors, but **there is no limit on the number of refreshes**. If the refreshed token is still invalid, the same refresh-retry loop repeats up to MAX_RETRIES(10). A per-session single-refresh limit should be implemented.

### C2. 429 Retry-After 20-Second Threshold
`Retry-After <= 20s`: sleep for the specified time then retry. `Retry-After > 20s`: 30-minute fast mode cooldown + model change trigger. If this 20-second threshold (`SHORT_RETRY_THRESHOLD_MS`) is undocumented, unexpected model downgrades may occur.

### C3. 529 Consecutive Errors — Subscriber Branching
`MAX_529_RETRIES = 3`. However, this threshold is only applied to **non-ClaudeAI subscribers + non-custom Opus models**. Subscribers are allowed more 529 retries. When this branching logic is undocumented, behavior varies across deployment environments.

### C4. Stream Idle Timeout 90 Seconds
`STREAM_IDLE_TIMEOUT_MS = 90000` (overridable via environment variable `CLAUDE_STREAM_IDLE_TIMEOUT_MS`). Warning at 45 seconds, stream abort at 90 seconds. "Idle" means **no chunks received at all**.

### C5. Settings Array Merge — Concat, Not Override
Settings arrays (permissions.deny, permissions.allow, etc.) from different sources are **concat + dedup**. They are not overridden. A deny from policySettings coexists with an allow from userSettings, and deny is checked first in the pipeline.

### C6. Token Counting Cross-Provider Inconsistency
Token counts from Bedrock, 1P API, and Vertex are **not guaranteed to match** (tokenizer version differences ~2%). Near the context window boundary, a "prompt too long" error may occur on only one provider. A 5-10% safety buffer is recommended.

### C7. PII Leakage — File Paths in Error Messages
MCP toolName is sanitized in analytics events, but **file paths in error messages are not sanitized**. User home directory paths may be sent as-is in logEvent() error fields.

---

## Appendix: Key Environment Variable Reference

| Environment Variable | Provider | Description |
|----------|----------|------|
| `ANTHROPIC_API_KEY` | Direct | API key |
| `ANTHROPIC_BASE_URL` | Direct | Custom base URL |
| `ANTHROPIC_AUTH_TOKEN` | Direct | Bearer token |
| `ANTHROPIC_CUSTOM_HEADERS` | All | Custom headers (newline delimited) |
| `CLAUDE_CODE_USE_BEDROCK` | Bedrock | Enable Bedrock |
| `AWS_REGION` | Bedrock | AWS region |
| `AWS_BEARER_TOKEN_BEDROCK` | Bedrock | Bearer token auth |
| `CLAUDE_CODE_USE_FOUNDRY` | Foundry | Enable Azure Foundry |
| `ANTHROPIC_FOUNDRY_RESOURCE` | Foundry | Azure resource name |
| `ANTHROPIC_FOUNDRY_API_KEY` | Foundry | Foundry API key |
| `CLAUDE_CODE_USE_VERTEX` | Vertex | Enable Vertex AI |
| `ANTHROPIC_VERTEX_PROJECT_ID` | Vertex | GCP project ID |
| `CLOUD_ML_REGION` | Vertex | GCP region |
| `API_TIMEOUT_MS` | All | Request timeout (default 600s) |
| `DISABLE_PROMPT_CACHING` | All | Disable prompt caching |
| `DISABLE_COMPACT` | All | Disable all context compaction |
| `DISABLE_AUTO_COMPACT` | All | Disable auto-compact only |
| `CLAUDE_CODE_EXTRA_BODY` | All | Additional API body parameters (JSON) |
| `CLAUDE_CODE_EXTRA_METADATA` | All | Additional metadata (JSON) |
| `CLAUDE_CODE_REMOTE` | All | Enable CCR mode |
| `CLAUDE_CODE_CONTAINER_ID` | CCR | Container ID |
| `CLAUDE_ENABLE_STREAM_WATCHDOG` | All | Enable stream idle watchdog |
| `CLAUDE_STREAM_IDLE_TIMEOUT_MS` | All | Idle timeout (default 90s) |
| `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | All | Auto-compact percent override |
| `CLAUDE_CODE_ADDITIONAL_PROTECTION` | All | Additional protection header |
