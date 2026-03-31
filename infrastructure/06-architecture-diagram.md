# 06 -- Architecture Diagrams

## 1. High-Level System Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          CLAUDE CODE CLI CLONE                          │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │                         CLI CLIENT LAYER                          │  │
│  │                                                                   │  │
│  │   ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────┐   │  │
│  │   │ Terminal  │  │ React+   │  │ Command  │  │ Input        │   │  │
│  │   │ Renderer  │  │ Ink TUI  │  │ Parser   │  │ Handler      │   │  │
│  │   │ (stdout)  │  │ (UI)     │  │ (Cmdr.js)│  │ (TextInput)  │   │  │
│  │   └────┬─────┘  └────┬─────┘  └────┬─────┘  └──────┬───────┘   │  │
│  │        │              │              │               │           │  │
│  │   ┌────▼──────────────▼──────────────▼───────────────▼───────┐  │  │
│  │   │                    QueryEngine                            │  │  │
│  │   │  - System prompt assembly                                 │  │  │
│  │   │  - Message history management                             │  │  │
│  │   │  - Streaming response handling                            │  │  │
│  │   │  - Tool dispatch loop                                     │  │  │
│  │   │  - Token counting & cost tracking                         │  │  │
│  │   └──────────────────────┬────────────────────────────────────┘  │  │
│  └──────────────────────────┼────────────────────────────────────────┘  │
│                             │                                           │
│  ┌──────────────────────────▼────────────────────────────────────────┐  │
│  │                       AGENT LAYER                                 │  │
│  │                                                                   │  │
│  │   ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐ │  │
│  │   │ Main Agent  │  │ Sub Agents  │  │ Coordinator             │ │  │
│  │   │ (default)   │  │ (AgentTool) │  │ (multi-agent mode)      │ │  │
│  │   │             │  │ - Parallel  │  │ - Task decomposition    │ │  │
│  │   │ Single      │  │ - Worker    │  │ - Worker management     │ │  │
│  │   │ conversation│  │ - Isolated  │  │ - Message routing       │ │  │
│  │   └──────┬──────┘  └──────┬──────┘  └────────────┬────────────┘ │  │
│  └──────────┼────────────────┼───────────────────────┼───────────────┘  │
│             │                │                       │                  │
│  ┌──────────▼────────────────▼───────────────────────▼───────────────┐  │
│  │                         TOOL LAYER                                │  │
│  │                                                                   │  │
│  │   ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ │  │
│  │   │  Bash   │ │ FileRead│ │FileWrite│ │FileEdit │ │  Glob   │ │  │
│  │   │  Tool   │ │  Tool   │ │  Tool   │ │  Tool   │ │  Tool   │ │  │
│  │   └─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘ │  │
│  │   ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ │  │
│  │   │  Grep   │ │ WebFetch│ │WebSearch│ │Notebook │ │  Agent  │ │  │
│  │   │  Tool   │ │  Tool   │ │  Tool   │ │EditTool │ │  Tool   │ │  │
│  │   └─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘ │  │
│  │   ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ │  │
│  │   │  Skill  │ │  Task   │ │  Cron   │ │  MCP    │ │ Custom  │ │  │
│  │   │  Tool   │ │  Tools  │ │  Tools  │ │  Tools  │ │  Tools  │ │  │
│  │   └─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘ │  │
│  └──────────────────────────────┬────────────────────────────────────┘  │
│                                 │                                       │
│  ┌──────────────────────────────▼────────────────────────────────────┐  │
│  │                       SERVICE LAYER                               │  │
│  │                                                                   │  │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────┐ ┌─────────┐ │  │
│  │  │ API      │ │ OAuth    │ │ MCP      │ │ Analy- │ │ Feature │ │  │
│  │  │ Client   │ │ Service  │ │ Client   │ │ tics   │ │ Flags   │ │  │
│  │  │ (claude) │ │ (auth)   │ │ (servers)│ │(OTel)  │ │(Growth- │ │  │
│  │  │          │ │          │ │          │ │        │ │ Book)   │ │  │
│  │  └──────────┘ └──────────┘ └──────────┘ └────────┘ └─────────┘ │  │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────┐             │  │
│  │  │ Plugin   │ │ Bridge   │ │ Session  │ │ Skill  │             │  │
│  │  │ System   │ │ (IDE)    │ │ Storage  │ │ System │             │  │
│  │  └──────────┘ └──────────┘ └──────────┘ └────────┘             │  │
│  └──────────────────────────────┬────────────────────────────────────┘  │
│                                 │                                       │
│  ┌──────────────────────────────▼────────────────────────────────────┐  │
│  │                        STATE LAYER                                │  │
│  │                                                                   │  │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────────────────┐  │  │
│  │  │ AppState │ │ Store<T> │ │ Async    │ │ React Context      │  │  │
│  │  │ Store    │ │ Pattern  │ │ Local    │ │ (UI state)         │  │  │
│  │  │ (global) │ │ (sub-    │ │ Storage  │ │                    │  │  │
│  │  │          │ │  stores) │ │ (agent   │ │                    │  │  │
│  │  │          │ │          │ │  context)│ │                    │  │  │
│  │  └──────────┘ └──────────┘ └──────────┘ └────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Data Flow Diagram

### 2.1 User Query to Response

```
User types prompt
        │
        ▼
┌─────────────────┐
│  processUser    │  Parse input, detect slash commands,
│  Input()        │  handle special inputs (/commit, /help)
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  fetchSystem    │  Assemble system prompt:
│  PromptParts()  │  - Base instructions
│────────────────│  - CLAUDE.md (project + global)
│                │  - Memory (auto + manual)
│                │  - Tool descriptions
│                │  - MCP tool schemas
│                │  - Skill instructions
│                │  - Context (git status, cwd, etc.)
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  query()        │  Send to LLM API:
│                 │  POST /v1/messages (streaming)
│  ┌────────────┐ │  - system prompt
│  │ Anthropic  │ │  - message history
│  │ SDK        │ │  - tool definitions
│  │ (streaming)│ │  - max_tokens, model
│  └──────┬─────┘ │
│         │       │
│         ▼       │
│  Stream events: │
│  ├─ message_start        → Update UI
│  ├─ content_block_start  → New text/tool block
│  ├─ content_block_delta  → Append text/input
│  ├─ content_block_stop   → Finalize block
│  └─ message_stop         → Complete response
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Tool Use?      │──── No ──→ Display response ──→ Wait for input
│  (tool_use      │
│   content block)│
└────────┬────────┘
         │ Yes
         ▼
┌─────────────────┐
│  Permission     │  Check permission mode:
│  Check          │  - allowedTools list
│────────────────│  - user approval (if needed)
│  AUTO / ASK /  │  - security policy
│  DENY          │
└────────┬────────┘
         │ Approved
         ▼
┌─────────────────┐
│  Execute Tool   │  Dispatch to tool implementation:
│                 │  ┌─────────────────────────┐
│                 │  │ BashTool   → subprocess │
│                 │  │ FileRead   → fs.read    │
│                 │  │ FileEdit   → diff+patch │
│                 │  │ GlobTool   → ripgrep    │
│                 │  │ GrepTool   → ripgrep    │
│                 │  │ AgentTool  → sub-query  │
│                 │  │ MCPTool    → MCP client │
│                 │  └─────────────────────────┘
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Append tool    │  Add tool_result to message history
│  result to      │  Run hooks (PostToolUse)
│  conversation   │  Record in session storage
└────────┬────────┘
         │
         ▼
    Loop back to query() with updated messages
    (agent loop continues until no more tool_use blocks)
```

### 2.2 Streaming Response Pipeline

```
Anthropic API
     │
     │  SSE Stream
     ▼
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  HTTP/2      │────>│  Event       │────>│  Content      │
│  Stream      │     │  Parser      │     │  Accumulator  │
│  Reader      │     │  (SSE)       │     │  (per block)  │
└──────────────┘     └──────────────┘     └──────┬───────┘
                                                  │
                            ┌─────────────────────┼──────────────┐
                            │                     │              │
                     ┌──────▼──────┐       ┌──────▼──────┐ ┌────▼─────┐
                     │  Text Block │       │ Tool Use    │ │ Thinking │
                     │  Renderer   │       │ Block       │ │ Block    │
                     │  (Ink)      │       │ Accumulate  │ │ (hidden) │
                     │             │       │ JSON input  │ │          │
                     └──────┬──────┘       └──────┬──────┘ └──────────┘
                            │                     │
                     ┌──────▼──────┐       ┌──────▼──────┐
                     │  Terminal   │       │  Tool       │
                     │  Display    │       │  Execution  │
                     │  (markdown) │       │  Pipeline   │
                     └─────────────┘       └─────────────┘
```

---

## 3. Authentication Flow

### 3.1 CLI OAuth 2.0 PKCE Flow

```
                CLI                    Browser               Auth Provider
                 │                        │                        │
                 │  1. Generate PKCE      │                        │
                 │     code_verifier      │                        │
                 │     code_challenge     │                        │
                 │                        │                        │
                 │  2. Start local HTTP   │                        │
                 │     server :14232      │                        │
                 │                        │                        │
                 │  3. Open browser ──────▶                        │
                 │     /authorize?        │  4. Login page         │
                 │     code_challenge=... │◀───────────────────────│
                 │     state=...          │                        │
                 │                        │  5. User enters        │
                 │                        │     credentials        │
                 │                        │────────────────────────▶
                 │                        │                        │
                 │                        │  6. Auth code          │
                 │                        │◀───────────────────────│
                 │                        │                        │
                 │  7. Redirect to        │                        │
                 │◀── localhost:14232     │                        │
                 │     /callback?code=... │                        │
                 │                        │                        │
                 │  8. Exchange code      │                        │
                 │     for tokens ────────────────────────────────▶│
                 │     POST /token        │                        │
                 │     + code_verifier    │                        │
                 │                        │                        │
                 │  9. Receive tokens ◀───────────────────────────│
                 │     access_token       │                        │
                 │     refresh_token      │                        │
                 │     id_token           │                        │
                 │                        │                        │
                 │  10. Store in          │                        │
                 │      OS Keychain       │                        │
                 │                        │                        │
                 │  11. Use access_token  │                        │
                 │      in API requests   │                        │
                 ▼                        ▼                        ▼
```

### 3.2 Token Refresh

```
CLI makes API request
        │
        ▼
┌─────────────────┐
│ Check token     │
│ expiry          │
└────────┬────────┘
         │
    ┌────┴────┐
    │ Expired?│
    └────┬────┘
         │ Yes
         ▼
┌─────────────────┐
│ POST /token     │
│ grant_type=     │
│ refresh_token   │
│ + refresh_token │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ New access_token│──→ Update keychain ──→ Retry original request
│ New refresh_token│
└─────────────────┘
```

---

## 4. Multi-Agent Execution Flow

### 4.1 Sub-Agent (AgentTool)

```
Main Agent
    │
    │  tool_use: Agent
    │  { type: "sub_agent", prompt: "..." }
    ▼
┌─────────────────────────────────────────────────────────┐
│                     Agent Tool                           │
│                                                         │
│  1. Create new QueryEngine instance                     │
│  2. Inherit parent's file state cache                   │
│  3. Set restricted tool set (if specified)              │
│  4. Run independent conversation loop                   │
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │  Sub-Agent Loop                                  │   │
│  │                                                  │   │
│  │  query() → response → tool_use → execute         │   │
│  │     ↑                              │             │   │
│  │     └──────────────────────────────┘             │   │
│  │                                                  │   │
│  │  Until: no more tool_use OR max_turns reached    │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  5. Return final response as tool_result to parent      │
└────────────────────────┬────────────────────────────────┘
                         │
                         ▼
              Main Agent continues with sub-agent result
```

### 4.2 Coordinator Mode (Multi-Worker)

```
User Request
     │
     ▼
┌─────────────────────────────────────────────────────────────┐
│                    COORDINATOR AGENT                         │
│                                                             │
│  1. Analyze request, decompose into tasks                   │
│  2. Create worker agents via TeamCreate                     │
│  3. Route messages between workers                          │
│                                                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐│
│  │  Worker A   │  │  Worker B   │  │  Worker C           ││
│  │ (frontend)  │  │ (backend)   │  │  (database)         ││
│  │             │  │             │  │                     ││
│  │ tools:      │  │ tools:      │  │ tools:              ││
│  │ - FileEdit  │  │ - FileEdit  │  │ - Bash (SQL)        ││
│  │ - FileRead  │  │ - FileRead  │  │ - FileWrite         ││
│  │ - Bash      │  │ - Bash      │  │ - FileRead          ││
│  │             │  │             │  │                     ││
│  │ model:      │  │ model:      │  │ model:              ││
│  │ sonnet-4    │  │ sonnet-4    │  │ sonnet-4            ││
│  └──────┬──────┘  └──────┬──────┘  └──────────┬──────────┘│
│         │                │                     │           │
│         └────────────────┼─────────────────────┘           │
│                          │                                  │
│  4. Aggregate results    │                                  │
│  5. Synthesize response  │                                  │
│                          │                                  │
└──────────────────────────┼──────────────────────────────────┘
                           │
                           ▼
                    Final Response to User
```

### 4.3 Agent State Isolation (AsyncLocalStorage)

```
┌──────────────────────────────────────────────────────────┐
│                    Process (Bun)                          │
│                                                          │
│  ┌─────────────────┐                                     │
│  │ AsyncLocalStorage│                                     │
│  │ ┌─────────────┐ │                                     │
│  │ │ Main Agent  │ │  Context: { cwd, sessionId,         │
│  │ │ Store       │ │           fileStateCache,            │
│  │ │             │ │           toolPermissions }          │
│  │ └─────────────┘ │                                     │
│  │ ┌─────────────┐ │                                     │
│  │ │ Sub-Agent A │ │  Context: { cwd, agentId,           │
│  │ │ Store       │ │           restrictedTools,           │
│  │ │             │ │           parentSnapshot }           │
│  │ └─────────────┘ │                                     │
│  │ ┌─────────────┐ │                                     │
│  │ │ Sub-Agent B │ │  Context: { cwd, agentId,           │
│  │ │ Store       │ │           restrictedTools }          │
│  │ └─────────────┘ │                                     │
│  └─────────────────┘                                     │
│                                                          │
│  Each agent runs in its own AsyncLocalStorage context.    │
│  File mutations are isolated; only committed changes      │
│  propagate back to the parent agent.                     │
└──────────────────────────────────────────────────────────┘
```

---

## 5. Deployment Topology

### 5.1 Single-Region Deployment

```
                    ┌─────────────────────────────┐
                    │         us-east-1            │
                    │                             │
  Internet ─────── │  ┌─────┐    ┌────────────┐  │
                    │  │ ALB │───>│ ECS Fargate│  │
                    │  │     │    │  api (x3)  │  │
                    │  └─────┘    └─────┬──────┘  │
                    │                   │         │
                    │           ┌───────┼───────┐ │
                    │           │       │       │ │
                    │      ┌────▼──┐ ┌──▼───┐ ┌─▼──────┐
                    │      │Lambda │ │Redis │ │Bedrock │
                    │      │(tool) │ │      │ │        │
                    │      └───────┘ └──────┘ └────────┘
                    │                   │         │
                    │              ┌────▼────┐    │
                    │              │   RDS   │    │
                    │              │  (AZ-a) │    │
                    │              │  (AZ-b) │    │
                    │              └─────────┘    │
                    │                             │
                    │      ┌────────┐ ┌────────┐  │
                    │      │   S3   │ │Cognito │  │
                    │      └────────┘ └────────┘  │
                    └─────────────────────────────┘

Latency: < 50ms (same region)
Availability: 99.9% (Multi-AZ)
Cost: Base infrastructure only
```

### 5.2 Multi-Region Deployment (Global)

```
                         ┌──────────────┐
                         │  CloudFront  │
                         │  (Global CDN)│
                         └───────┬──────┘
                                 │
                    ┌────────────┼────────────┐
                    │            │            │
            ┌───────▼──────┐ ┌──▼──────────┐ ┌▼──────────────┐
            │  us-east-1   │ │ eu-west-1   │ │ ap-northeast-1│
            │              │ │             │ │               │
            │ ┌──────────┐ │ │ ┌─────────┐│ │ ┌───────────┐ │
            │ │ECS (API) │ │ │ │ECS (API)││ │ │ECS (API)  │ │
            │ └─────┬────┘ │ │ └────┬────┘│ │ └─────┬─────┘ │
            │       │      │ │      │     │ │       │       │
            │ ┌─────▼────┐ │ │ ┌────▼───┐│ │ ┌─────▼─────┐ │
            │ │RDS Primary│ │ │ │RDS Read││ │ │RDS Read   │ │
            │ └──────────┘ │ │ │Replica ││ │ │Replica    │ │
            │              │ │ └────────┘│ │ └───────────┘ │
            │ ┌──────────┐ │ │ ┌────────┐│ │ ┌───────────┐ │
            │ │Bedrock   │ │ │ │Bedrock ││ │ │Bedrock    │ │
            │ │(Claude)  │ │ │ │(Claude)││ │ │(Claude)   │ │
            │ └──────────┘ │ │ └────────┘│ │ └───────────┘ │
            │              │ │           │ │               │
            │ ┌──────────┐ │ │ ┌────────┐│ │ ┌───────────┐ │
            │ │S3 Primary│─┼─┼─│S3 Repl.││ │ │S3 Repl.   │ │
            │ └──────────┘ │ │ └────────┘│ │ └───────────┘ │
            └──────────────┘ └───────────┘ └───────────────┘

Global Latency: < 100ms (any region)
Availability: 99.99%
Cost: ~3x single-region infrastructure
Note: Bedrock is available in multiple regions with same model access
```

### 5.3 Hybrid Deployment (Cloud + Local GPU)

```
                    ┌─────────────────────────────┐
                    │          AWS Cloud           │
                    │                             │
  Internet ─────── │  ┌─────┐    ┌────────────┐  │
                    │  │ ALB │───>│ ECS Fargate│  │
                    │  │     │    │  api (x2)  │  │
                    │  └─────┘    └─────┬──────┘  │
                    │                   │         │
                    │         ┌─────────┤         │
                    │         │         │         │
                    │    ┌────▼──┐ ┌────▼────┐    │
                    │    │Redis │ │   RDS   │    │
                    │    └──────┘ └─────────┘    │
                    └────────────┬────────────────┘
                                │
                    ┌───────────▼────────────────┐
                    │    VPN / Direct Connect     │
                    └───────────┬────────────────┘
                                │
                    ┌───────────▼────────────────┐
                    │      On-Premise / Colo      │
                    │                             │
                    │  ┌─────────────────────┐    │
                    │  │  GPU Inference      │    │
                    │  │  Server             │    │
                    │  │  ┌───────────────┐  │    │
                    │  │  │ vLLM          │  │    │
                    │  │  │ Qwen2.5-32B   │  │    │
                    │  │  │ or Llama-70B  │  │    │
                    │  │  └───────────────┘  │    │
                    │  │  2x RTX 4090 /     │    │
                    │  │  A100 80GB         │    │
                    │  └─────────────────────┘    │
                    └─────────────────────────────┘

Routing: Simple tasks → Local GPU
         Complex tasks → Cloud (Bedrock/Anthropic)
Cost: ~60-73% savings on tokens
```

---

## 6. MCP Server Integration Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                     MCP Server Lifecycle                        │
│                                                                 │
│  ┌──────────┐     ┌──────────┐     ┌──────────┐               │
│  │  Config   │────>│  Launch  │────>│  Init    │               │
│  │  (.mcp.   │     │  Process │     │  (hand-  │               │
│  │   json)   │     │  (stdio) │     │   shake) │               │
│  └──────────┘     └──────────┘     └────┬─────┘               │
│                                          │                      │
│                                    ┌─────▼──────┐              │
│                                    │  Register  │              │
│                                    │  Tools     │              │
│                                    │  Resources │              │
│                                    │  Prompts   │              │
│                                    └─────┬──────┘              │
│                                          │                      │
│  Agent requests mcp_tool_call:           │                      │
│  ┌──────────────────┐              ┌─────▼──────┐              │
│  │ tool_use:        │              │            │              │
│  │   mcp__server__  │─────────────>│  MCP Client│              │
│  │   tool_name      │              │  (SDK)     │              │
│  │   { args }       │              │            │              │
│  └──────────────────┘              └─────┬──────┘              │
│                                          │                      │
│                                    ┌─────▼──────┐              │
│                                    │  MCP Server│              │
│                                    │  Process   │              │
│                                    │  (stdio /  │              │
│                                    │   HTTP)    │              │
│                                    └─────┬──────┘              │
│                                          │                      │
│                                    ┌─────▼──────┐              │
│                                    │  Result    │              │
│                                    │  (JSON)    │──> tool_result│
│                                    └────────────┘              │
│                                                                 │
│  Transport Options:                                             │
│  ┌──────┐  ┌──────┐  ┌──────┐  ┌──────┐                      │
│  │stdio │  │ SSE  │  │ HTTP │  │  WS  │                      │
│  │(local)│  │(remote)│ │(REST)│  │(bidi)│                      │
│  └──────┘  └──────┘  └──────┘  └──────┘                      │
└─────────────────────────────────────────────────────────────────┘
```

---

## 7. Session Persistence Flow

```
┌─────────────────────────────────────────────────────────────┐
│                  Session Lifecycle                           │
│                                                             │
│  START SESSION                                              │
│  ┌──────────┐                                               │
│  │ Generate │──> session_id = UUID                          │
│  │ Session  │──> Store in DB (sessions table)               │
│  │ ID       │──> Set in AppState store                      │
│  └──────────┘                                               │
│                                                             │
│  DURING SESSION                                             │
│  Each API turn:                                             │
│  ┌──────────┐                                               │
│  │ Record   │──> Append to messages table                   │
│  │ Trans-   │──> Write JSONL transcript to S3               │
│  │ cript    │──> Update session stats (tokens, cost)        │
│  └──────────┘                                               │
│                                                             │
│  Each tool execution:                                       │
│  ┌──────────┐                                               │
│  │ Record   │──> Insert tool_results row                    │
│  │ Tool     │──> Append to audit_log                        │
│  │ Result   │──> Update tool stats in session               │
│  └──────────┘                                               │
│                                                             │
│  COMPACT / SUMMARIZE                                        │
│  ┌──────────┐                                               │
│  │ Context  │──> Summarize old messages                     │
│  │ Window   │──> Replace with synthetic summary             │
│  │ Mgmt     │──> Keep last N messages in full               │
│  └──────────┘                                               │
│                                                             │
│  RESUME SESSION                                             │
│  ┌──────────┐                                               │
│  │ Load     │──> Query messages by session_id               │
│  │ History  │──> Reconstruct file state cache               │
│  │          │──> Restore agent state (if multi-agent)       │
│  │          │──> Replay pending tool results                │
│  └──────────┘                                               │
│                                                             │
│  END SESSION                                                │
│  ┌──────────┐                                               │
│  │ Flush    │──> Final transcript write                     │
│  │ & Close  │──> Set is_active = false                      │
│  │          │──> Record ended_at                            │
│  │          │──> Update cumulative usage                    │
│  └──────────┘                                               │
└─────────────────────────────────────────────────────────────┘
```
