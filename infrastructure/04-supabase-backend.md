# 04 -- Supabase Backend

## Overview

Supabase provides a unified backend with PostgreSQL database, Row Level Security, Realtime subscriptions, Edge Functions, Authentication, and Storage. This is the fastest path to production for small teams and the most cost-effective for startups.

---

## 1. Architecture with Supabase

```
CLI Client
  │
  ├──> Supabase Auth (login, token refresh)
  │
  ├──> Supabase Realtime (WebSocket, streaming LLM responses)
  │
  ├──> Supabase REST/PostgREST (session CRUD, messages, settings)
  │
  ├──> Supabase Edge Functions (tool execution, LLM proxy, MCP bridge)
  │
  ├──> Supabase Storage (file artifacts, snapshots)
  │
  └──> External LLM API (Anthropic / OpenAI / Bedrock)
       (proxied via Edge Functions for key protection)
```

---

## 2. Database Schema

### 2.1 Complete Schema

```sql
-- ============================================================
-- Migration: 20260331000001_initial_schema.sql
-- Claude Code CLI Clone - Complete Database Schema
-- ============================================================

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";    -- For text search

-- ============================================================
-- USERS & PROFILES
-- ============================================================

CREATE TABLE public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  display_name TEXT,
  avatar_url TEXT,
  plan TEXT NOT NULL DEFAULT 'free'
    CHECK (plan IN ('free', 'pro', 'team', 'enterprise')),
  org_id UUID,
  api_key_encrypted TEXT,          -- Encrypted Anthropic API key
  model_preference TEXT DEFAULT 'claude-sonnet-4-20250514',
  max_tokens_per_day INTEGER DEFAULT 500000,
  tokens_used_today INTEGER DEFAULT 0,
  tokens_reset_at TIMESTAMPTZ DEFAULT now(),
  settings JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_profiles_org ON public.profiles(org_id);
CREATE INDEX idx_profiles_email ON public.profiles(email);

-- ============================================================
-- SESSIONS
-- ============================================================

CREATE TABLE public.sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  title TEXT,
  cwd TEXT NOT NULL,                -- Working directory
  mode TEXT NOT NULL DEFAULT 'normal'
    CHECK (mode IN ('normal', 'coordinator', 'plan', 'fast')),
  model TEXT NOT NULL DEFAULT 'claude-sonnet-4-20250514',
  total_input_tokens BIGINT DEFAULT 0,
  total_output_tokens BIGINT DEFAULT 0,
  total_cache_read_tokens BIGINT DEFAULT 0,
  total_cache_creation_tokens BIGINT DEFAULT 0,
  total_cost_usd NUMERIC(10,6) DEFAULT 0,
  total_tool_calls INTEGER DEFAULT 0,
  total_api_duration_ms BIGINT DEFAULT 0,
  message_count INTEGER DEFAULT 0,
  is_active BOOLEAN DEFAULT true,
  resumed_from UUID REFERENCES public.sessions(id),
  coordinator_mode TEXT
    CHECK (coordinator_mode IN ('coordinator', 'normal')),
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  ended_at TIMESTAMPTZ
);

CREATE INDEX idx_sessions_user ON public.sessions(user_id);
CREATE INDEX idx_sessions_active ON public.sessions(user_id, is_active) WHERE is_active = true;
CREATE INDEX idx_sessions_created ON public.sessions(created_at DESC);

-- ============================================================
-- MESSAGES
-- ============================================================

CREATE TABLE public.messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID NOT NULL REFERENCES public.sessions(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'system')),
  content JSONB NOT NULL,           -- ContentBlockParam[] format
  model TEXT,                        -- Model used for this response
  input_tokens INTEGER DEFAULT 0,
  output_tokens INTEGER DEFAULT 0,
  cache_read_tokens INTEGER DEFAULT 0,
  cache_creation_tokens INTEGER DEFAULT 0,
  cost_usd NUMERIC(10,6) DEFAULT 0,
  duration_ms INTEGER DEFAULT 0,
  stop_reason TEXT,
  sequence_number INTEGER NOT NULL,
  is_synthetic BOOLEAN DEFAULT false,  -- Synthetic messages (system-injected)
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_messages_session ON public.messages(session_id, sequence_number);
CREATE INDEX idx_messages_user ON public.messages(user_id);
CREATE INDEX idx_messages_created ON public.messages(created_at DESC);

-- ============================================================
-- TOOL RESULTS
-- ============================================================

CREATE TABLE public.tool_results (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id UUID NOT NULL REFERENCES public.messages(id) ON DELETE CASCADE,
  session_id UUID NOT NULL REFERENCES public.sessions(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  tool_use_id TEXT NOT NULL,         -- Matches Claude API tool_use block id
  tool_name TEXT NOT NULL,
  input JSONB NOT NULL,              -- Tool input parameters
  output JSONB,                      -- Tool result
  is_error BOOLEAN DEFAULT false,
  error_message TEXT,
  duration_ms INTEGER DEFAULT 0,
  sandbox_id TEXT,                   -- Lambda/Function execution ID
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_tool_results_message ON public.tool_results(message_id);
CREATE INDEX idx_tool_results_session ON public.tool_results(session_id);
CREATE INDEX idx_tool_results_tool ON public.tool_results(tool_name);

-- ============================================================
-- AGENTS (Multi-Agent / Coordinator Mode)
-- ============================================================

CREATE TABLE public.agents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID NOT NULL REFERENCES public.sessions(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  parent_agent_id UUID REFERENCES public.agents(id),
  agent_type TEXT NOT NULL,          -- 'main', 'sub', 'coordinator', 'worker'
  name TEXT NOT NULL,
  model TEXT NOT NULL,
  system_prompt TEXT,
  allowed_tools TEXT[],              -- Tool whitelist
  state TEXT NOT NULL DEFAULT 'active'
    CHECK (state IN ('active', 'paused', 'completed', 'error')),
  total_input_tokens BIGINT DEFAULT 0,
  total_output_tokens BIGINT DEFAULT 0,
  total_cost_usd NUMERIC(10,6) DEFAULT 0,
  context JSONB DEFAULT '{}'::jsonb,  -- Agent-specific state
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  ended_at TIMESTAMPTZ
);

CREATE INDEX idx_agents_session ON public.agents(session_id);
CREATE INDEX idx_agents_parent ON public.agents(parent_agent_id);

-- ============================================================
-- MEMORIES (Auto-Memory / Manual Memory)
-- ============================================================

CREATE TABLE public.memories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  session_id UUID REFERENCES public.sessions(id) ON DELETE SET NULL,
  type TEXT NOT NULL CHECK (type IN ('auto', 'manual', 'project', 'global')),
  category TEXT,                     -- 'preference', 'context', 'instruction', etc.
  content TEXT NOT NULL,
  embedding vector(1536),            -- For semantic search (pgvector)
  project_path TEXT,                 -- Project-scoped memories
  relevance_score NUMERIC(3,2) DEFAULT 1.0,
  access_count INTEGER DEFAULT 0,
  last_accessed_at TIMESTAMPTZ,
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_memories_user ON public.memories(user_id);
CREATE INDEX idx_memories_type ON public.memories(user_id, type);
CREATE INDEX idx_memories_project ON public.memories(user_id, project_path);
-- Vector similarity search index (if pgvector extension available)
-- CREATE INDEX idx_memories_embedding ON public.memories
--   USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

-- ============================================================
-- SETTINGS (User/Project/Org Configuration)
-- ============================================================

CREATE TABLE public.settings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  scope TEXT NOT NULL CHECK (scope IN ('user', 'project', 'org')),
  scope_key TEXT,                    -- project path or org_id
  category TEXT NOT NULL,            -- 'permissions', 'model', 'mcp', 'hooks', etc.
  key TEXT NOT NULL,
  value JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  UNIQUE(user_id, scope, scope_key, category, key)
);

CREATE INDEX idx_settings_user ON public.settings(user_id);
CREATE INDEX idx_settings_scope ON public.settings(user_id, scope, scope_key);

-- ============================================================
-- MCP SERVERS (Model Context Protocol Server Registry)
-- ============================================================

CREATE TABLE public.mcp_servers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  scope TEXT NOT NULL DEFAULT 'user'
    CHECK (scope IN ('local', 'user', 'project', 'dynamic')),
  transport TEXT NOT NULL CHECK (transport IN ('stdio', 'sse', 'http', 'ws')),
  config JSONB NOT NULL,             -- command, args, env, url, etc.
  is_active BOOLEAN DEFAULT true,
  last_connected_at TIMESTAMPTZ,
  last_error TEXT,
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  UNIQUE(user_id, name, scope)
);

CREATE INDEX idx_mcp_servers_user ON public.mcp_servers(user_id);

-- ============================================================
-- USAGE TRACKING
-- ============================================================

CREATE TABLE public.usage_daily (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  date DATE NOT NULL DEFAULT CURRENT_DATE,
  model TEXT NOT NULL,
  input_tokens BIGINT DEFAULT 0,
  output_tokens BIGINT DEFAULT 0,
  cache_read_tokens BIGINT DEFAULT 0,
  cache_creation_tokens BIGINT DEFAULT 0,
  cost_usd NUMERIC(10,6) DEFAULT 0,
  request_count INTEGER DEFAULT 0,
  tool_calls INTEGER DEFAULT 0,
  sessions_count INTEGER DEFAULT 0,

  UNIQUE(user_id, date, model)
);

CREATE INDEX idx_usage_daily_user ON public.usage_daily(user_id, date DESC);

-- ============================================================
-- AUDIT LOG
-- ============================================================

CREATE TABLE public.audit_log (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  session_id UUID REFERENCES public.sessions(id),
  action TEXT NOT NULL,              -- 'tool_exec', 'file_write', 'bash_exec', etc.
  resource TEXT,                     -- File path, command, etc.
  result TEXT,                       -- 'success', 'error', 'denied'
  details JSONB DEFAULT '{}'::jsonb,
  ip_address INET,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_audit_log_user ON public.audit_log(user_id, created_at DESC);
CREATE INDEX idx_audit_log_session ON public.audit_log(session_id);

-- ============================================================
-- HELPER FUNCTIONS
-- ============================================================

-- Auto-update updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply to all tables with updated_at
DO $$
DECLARE
  t TEXT;
BEGIN
  FOR t IN SELECT unnest(ARRAY[
    'profiles', 'sessions', 'agents', 'memories', 'settings', 'mcp_servers'
  ])
  LOOP
    EXECUTE format(
      'CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.%I
       FOR EACH ROW EXECUTE FUNCTION update_updated_at_column()', t
    );
  END LOOP;
END;
$$;

-- Auto-increment message sequence number
CREATE OR REPLACE FUNCTION set_message_sequence()
RETURNS TRIGGER AS $$
BEGIN
  NEW.sequence_number = COALESCE(
    (SELECT MAX(sequence_number) FROM public.messages WHERE session_id = NEW.session_id),
    0
  ) + 1;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_message_sequence
  BEFORE INSERT ON public.messages
  FOR EACH ROW EXECUTE FUNCTION set_message_sequence();

-- Daily token reset
CREATE OR REPLACE FUNCTION reset_daily_tokens()
RETURNS void AS $$
BEGIN
  UPDATE public.profiles
  SET tokens_used_today = 0,
      tokens_reset_at = now()
  WHERE tokens_reset_at < CURRENT_DATE;
END;
$$ LANGUAGE plpgsql;

-- Aggregate session stats after message insert
CREATE OR REPLACE FUNCTION update_session_stats()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE public.sessions
  SET total_input_tokens = total_input_tokens + NEW.input_tokens,
      total_output_tokens = total_output_tokens + NEW.output_tokens,
      total_cache_read_tokens = total_cache_read_tokens + NEW.cache_read_tokens,
      total_cache_creation_tokens = total_cache_creation_tokens + NEW.cache_creation_tokens,
      total_cost_usd = total_cost_usd + NEW.cost_usd,
      total_api_duration_ms = total_api_duration_ms + NEW.duration_ms,
      message_count = message_count + 1,
      updated_at = now()
  WHERE id = NEW.session_id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_session_stats_on_message
  AFTER INSERT ON public.messages
  FOR EACH ROW EXECUTE FUNCTION update_session_stats();
```

---

## 3. Row Level Security (RLS) Policies

```sql
-- ============================================================
-- Migration: 20260331000002_rls_policies.sql
-- Row Level Security for all tables
-- ============================================================

-- Enable RLS on all tables
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tool_results ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.memories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mcp_servers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.usage_daily ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- PROFILES
-- ============================================================

CREATE POLICY "profiles_select_own"
  ON public.profiles FOR SELECT
  USING (id = auth.uid());

CREATE POLICY "profiles_update_own"
  ON public.profiles FOR UPDATE
  USING (id = auth.uid())
  WITH CHECK (id = auth.uid());

-- Insert handled by auth trigger (create profile on signup)

-- ============================================================
-- SESSIONS
-- ============================================================

CREATE POLICY "sessions_select_own"
  ON public.sessions FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY "sessions_insert_own"
  ON public.sessions FOR INSERT
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "sessions_update_own"
  ON public.sessions FOR UPDATE
  USING (user_id = auth.uid());

CREATE POLICY "sessions_delete_own"
  ON public.sessions FOR DELETE
  USING (user_id = auth.uid());

-- ============================================================
-- MESSAGES
-- ============================================================

CREATE POLICY "messages_select_own"
  ON public.messages FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY "messages_insert_own"
  ON public.messages FOR INSERT
  WITH CHECK (user_id = auth.uid());

-- Messages are append-only (no update/delete)

-- ============================================================
-- TOOL RESULTS
-- ============================================================

CREATE POLICY "tool_results_select_own"
  ON public.tool_results FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY "tool_results_insert_own"
  ON public.tool_results FOR INSERT
  WITH CHECK (user_id = auth.uid());

-- Tool results are append-only

-- ============================================================
-- AGENTS
-- ============================================================

CREATE POLICY "agents_select_own"
  ON public.agents FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY "agents_insert_own"
  ON public.agents FOR INSERT
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "agents_update_own"
  ON public.agents FOR UPDATE
  USING (user_id = auth.uid());

-- ============================================================
-- MEMORIES
-- ============================================================

CREATE POLICY "memories_select_own"
  ON public.memories FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY "memories_insert_own"
  ON public.memories FOR INSERT
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "memories_update_own"
  ON public.memories FOR UPDATE
  USING (user_id = auth.uid());

CREATE POLICY "memories_delete_own"
  ON public.memories FOR DELETE
  USING (user_id = auth.uid());

-- ============================================================
-- SETTINGS
-- ============================================================

CREATE POLICY "settings_select_own"
  ON public.settings FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY "settings_insert_own"
  ON public.settings FOR INSERT
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "settings_update_own"
  ON public.settings FOR UPDATE
  USING (user_id = auth.uid());

CREATE POLICY "settings_delete_own"
  ON public.settings FOR DELETE
  USING (user_id = auth.uid());

-- ============================================================
-- MCP SERVERS
-- ============================================================

CREATE POLICY "mcp_servers_select_own"
  ON public.mcp_servers FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY "mcp_servers_insert_own"
  ON public.mcp_servers FOR INSERT
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "mcp_servers_update_own"
  ON public.mcp_servers FOR UPDATE
  USING (user_id = auth.uid());

CREATE POLICY "mcp_servers_delete_own"
  ON public.mcp_servers FOR DELETE
  USING (user_id = auth.uid());

-- ============================================================
-- USAGE DAILY
-- ============================================================

CREATE POLICY "usage_daily_select_own"
  ON public.usage_daily FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY "usage_daily_insert_own"
  ON public.usage_daily FOR INSERT
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "usage_daily_update_own"
  ON public.usage_daily FOR UPDATE
  USING (user_id = auth.uid());

-- ============================================================
-- AUDIT LOG
-- ============================================================

CREATE POLICY "audit_log_select_own"
  ON public.audit_log FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY "audit_log_insert_own"
  ON public.audit_log FOR INSERT
  WITH CHECK (user_id = auth.uid());

-- Audit logs are append-only (no update/delete)

-- ============================================================
-- ORG-LEVEL POLICIES (Team/Enterprise plans)
-- ============================================================

-- Org admins can view all org members' usage
CREATE POLICY "usage_daily_org_admin"
  ON public.usage_daily FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = auth.uid()
        AND p.org_id = (SELECT org_id FROM public.profiles WHERE id = usage_daily.user_id)
        AND (p.settings->>'role')::text = 'admin'
    )
  );
```

---

## 4. Edge Functions

### 4.1 LLM Proxy (Protects API Keys)

```typescript
// supabase/functions/llm-proxy/index.ts
import { serve } from "https://deno.land/std@0.208.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Anthropic from "https://esm.sh/@anthropic-ai/sdk@0.30";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  // Authenticate user
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: req.headers.get("Authorization")! } } }
  );

  const { data: { user }, error: authError } = await supabase.auth.getUser();
  if (authError || !user) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  // Check rate limits
  const { data: profile } = await supabase
    .from("profiles")
    .select("tokens_used_today, max_tokens_per_day, model_preference, api_key_encrypted")
    .eq("id", user.id)
    .single();

  if (profile && profile.tokens_used_today >= profile.max_tokens_per_day) {
    return new Response(JSON.stringify({ error: "Daily token limit exceeded" }), {
      status: 429,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  // Get API key (user's own or platform key)
  const apiKey = profile?.api_key_encrypted
    ? await decryptApiKey(profile.api_key_encrypted)
    : Deno.env.get("ANTHROPIC_API_KEY")!;

  const anthropic = new Anthropic({ apiKey });

  // Parse request
  const body = await req.json();
  const { model, messages, tools, max_tokens, system, stream } = body;

  if (stream) {
    // Streaming response via Server-Sent Events
    const encoder = new TextEncoder();
    const readableStream = new ReadableStream({
      async start(controller) {
        try {
          const streamResponse = anthropic.messages.stream({
            model: model || profile?.model_preference || "claude-sonnet-4-20250514",
            messages,
            tools,
            max_tokens: max_tokens || 8192,
            system,
          });

          for await (const event of streamResponse) {
            controller.enqueue(
              encoder.encode(`data: ${JSON.stringify(event)}\n\n`)
            );
          }

          // Update usage
          const finalMessage = await streamResponse.finalMessage();
          await updateUsage(supabase, user.id, finalMessage.usage);

          controller.enqueue(encoder.encode("data: [DONE]\n\n"));
          controller.close();
        } catch (error) {
          controller.enqueue(
            encoder.encode(`data: ${JSON.stringify({ error: error.message })}\n\n`)
          );
          controller.close();
        }
      },
    });

    return new Response(readableStream, {
      headers: {
        ...corsHeaders,
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        "Connection": "keep-alive",
      },
    });
  }

  // Non-streaming response
  const response = await anthropic.messages.create({
    model: model || profile?.model_preference || "claude-sonnet-4-20250514",
    messages,
    tools,
    max_tokens: max_tokens || 8192,
    system,
  });

  await updateUsage(supabase, user.id, response.usage);

  return new Response(JSON.stringify(response), {
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
});

async function updateUsage(supabase: any, userId: string, usage: any) {
  const { input_tokens = 0, output_tokens = 0 } = usage;
  await supabase.rpc("increment_usage", {
    p_user_id: userId,
    p_input_tokens: input_tokens,
    p_output_tokens: output_tokens,
  });
}

async function decryptApiKey(encrypted: string): Promise<string> {
  // In production, use Supabase Vault or a KMS
  return encrypted; // Simplified
}
```

### 4.2 Tool Execution Sandbox

```typescript
// supabase/functions/tool-executor/index.ts
import { serve } from "https://deno.land/std@0.208.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const MAX_EXEC_TIME = 30_000; // 30 seconds for Edge Functions
const MAX_OUTPUT_SIZE = 1_000_000; // 1MB

serve(async (req) => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  // Auth check
  const authHeader = req.headers.get("Authorization");
  const { data: { user } } = await supabase.auth.getUser(
    authHeader?.replace("Bearer ", "")
  );
  if (!user) return new Response("Unauthorized", { status: 401 });

  const { tool_name, input, session_id, tool_use_id } = await req.json();

  const startTime = Date.now();
  let result: any;
  let isError = false;

  try {
    switch (tool_name) {
      case "bash":
        result = await executeBash(input.command, input.timeout);
        break;
      case "file_read":
        result = await readFile(input.file_path, input.offset, input.limit);
        break;
      case "file_write":
        result = await writeFile(input.file_path, input.content);
        break;
      case "file_edit":
        result = await editFile(input.file_path, input.old_string, input.new_string);
        break;
      case "glob":
        result = await globSearch(input.pattern, input.path);
        break;
      case "grep":
        result = await grepSearch(input.pattern, input.path, input.options);
        break;
      default:
        throw new Error(`Unknown tool: ${tool_name}`);
    }
  } catch (error) {
    isError = true;
    result = { error: error.message };
  }

  const duration = Date.now() - startTime;

  // Store result
  await supabase.from("tool_results").insert({
    message_id: null,  // Will be linked by the message handler
    session_id,
    user_id: user.id,
    tool_use_id,
    tool_name,
    input,
    output: result,
    is_error: isError,
    error_message: isError ? result.error : null,
    duration_ms: duration,
  });

  // Audit log
  await supabase.from("audit_log").insert({
    user_id: user.id,
    session_id,
    action: `tool_exec:${tool_name}`,
    resource: input.file_path || input.command || input.pattern,
    result: isError ? "error" : "success",
    details: { duration_ms: duration, tool_use_id },
  });

  return new Response(JSON.stringify(result), {
    headers: { "Content-Type": "application/json" },
  });
});

async function executeBash(command: string, timeout = 30000): Promise<any> {
  // Deno subprocess execution
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), Math.min(timeout, MAX_EXEC_TIME));

  try {
    const process = new Deno.Command("bash", {
      args: ["-c", command],
      stdout: "piped",
      stderr: "piped",
      signal: controller.signal,
    });

    const { code, stdout, stderr } = await process.output();
    const decoder = new TextDecoder();

    return {
      exit_code: code,
      stdout: decoder.decode(stdout).slice(0, MAX_OUTPUT_SIZE),
      stderr: decoder.decode(stderr).slice(0, MAX_OUTPUT_SIZE),
    };
  } finally {
    clearTimeout(timer);
  }
}

async function readFile(path: string, offset?: number, limit?: number): Promise<any> {
  const content = await Deno.readTextFile(path);
  const lines = content.split("\n");
  const start = offset || 0;
  const end = limit ? start + limit : lines.length;
  return {
    content: lines.slice(start, end).map((line, i) => `${start + i + 1}\t${line}`).join("\n"),
    total_lines: lines.length,
  };
}

async function writeFile(path: string, content: string): Promise<any> {
  await Deno.writeTextFile(path, content);
  return { success: true, bytes_written: new TextEncoder().encode(content).length };
}

async function editFile(path: string, oldStr: string, newStr: string): Promise<any> {
  const content = await Deno.readTextFile(path);
  if (!content.includes(oldStr)) {
    throw new Error("old_string not found in file");
  }
  const occurrences = content.split(oldStr).length - 1;
  if (occurrences > 1) {
    throw new Error(`old_string found ${occurrences} times, must be unique`);
  }
  const newContent = content.replace(oldStr, newStr);
  await Deno.writeTextFile(path, newContent);
  return { success: true };
}

async function globSearch(pattern: string, basePath?: string): Promise<any> {
  // Simplified glob using Deno.readDir
  const results: string[] = [];
  // In production, use a proper glob library
  return { files: results };
}

async function grepSearch(pattern: string, path?: string, options?: any): Promise<any> {
  const process = new Deno.Command("rg", {
    args: [pattern, path || ".", "--json", "-l"],
    stdout: "piped",
    stderr: "piped",
  });
  const { stdout } = await process.output();
  return { output: new TextDecoder().decode(stdout).slice(0, MAX_OUTPUT_SIZE) };
}
```

### 4.3 MCP Bridge

```typescript
// supabase/functions/mcp-bridge/index.ts
import { serve } from "https://deno.land/std@0.208.0/http/server.ts";
import { Client } from "https://esm.sh/@modelcontextprotocol/sdk@1/client/index.js";

serve(async (req) => {
  const { action, server_config, tool_name, arguments: args } = await req.json();

  switch (action) {
    case "connect":
      return handleConnect(server_config);
    case "list_tools":
      return handleListTools(server_config);
    case "call_tool":
      return handleCallTool(server_config, tool_name, args);
    default:
      return new Response(JSON.stringify({ error: "Unknown action" }), { status: 400 });
  }
});

async function handleConnect(config: any) {
  // Validate and test MCP server connection
  return new Response(JSON.stringify({ status: "connected" }));
}

async function handleListTools(config: any) {
  // Return available tools from MCP server
  return new Response(JSON.stringify({ tools: [] }));
}

async function handleCallTool(config: any, toolName: string, args: any) {
  // Execute tool via MCP server
  return new Response(JSON.stringify({ result: null }));
}
```

---

## 5. Realtime for Streaming

### 5.1 Realtime Channel Design

```typescript
// Client-side: Subscribe to streaming LLM responses
const channel = supabase.channel(`session:${sessionId}`)
  .on("broadcast", { event: "llm_stream" }, (payload) => {
    // Handle streaming content blocks
    switch (payload.type) {
      case "content_block_start":
        // New text or tool_use block
        break;
      case "content_block_delta":
        // Incremental text delta
        break;
      case "content_block_stop":
        // Block complete
        break;
      case "message_stop":
        // Full response complete
        break;
    }
  })
  .on("broadcast", { event: "tool_result" }, (payload) => {
    // Tool execution result
  })
  .subscribe();

// Server-side (Edge Function): Broadcast LLM stream events
for await (const event of anthropicStream) {
  await supabase.channel(`session:${sessionId}`).send({
    type: "broadcast",
    event: "llm_stream",
    payload: event,
  });
}
```

### 5.2 Presence for Multi-Agent

```typescript
// Track active agents in a session
const channel = supabase.channel(`agents:${sessionId}`)
  .on("presence", { event: "sync" }, () => {
    const agents = channel.presenceState();
    // { agent_id: { agent_type, model, state, online_at } }
  })
  .subscribe(async (status) => {
    if (status === "SUBSCRIBED") {
      await channel.track({
        agent_id: agentId,
        agent_type: "main",
        model: "claude-sonnet-4",
        state: "active",
      });
    }
  });
```

---

## 6. Auth Configuration

### 6.1 Supabase Auth Setup

```sql
-- Create profile on user signup
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, email, display_name)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'full_name', split_part(NEW.email, '@', 1))
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();
```

### 6.2 CLI Auth Flow

```
1. CLI generates PKCE code_verifier + code_challenge
2. CLI starts local HTTP server on port 14232
3. CLI opens browser:
   https://<project>.supabase.co/auth/v1/authorize?
     provider=github&
     redirect_to=http://localhost:14232/callback&
     code_challenge=<challenge>&
     code_challenge_method=S256

4. User authenticates via GitHub/Google/Email
5. Supabase redirects to localhost:14232/callback?code=<auth_code>
6. CLI exchanges code for tokens:
   POST https://<project>.supabase.co/auth/v1/token?grant_type=authorization_code
   { code, code_verifier, redirect_uri }
7. CLI stores access_token + refresh_token in OS keychain
8. CLI uses access_token in Authorization header for all requests
```

---

## 7. Storage for File Artifacts

```typescript
// Upload file snapshot
const { data, error } = await supabase.storage
  .from("sessions")
  .upload(
    `${userId}/${sessionId}/snapshots/${snapshotId}.tar.gz`,
    fileBuffer,
    { contentType: "application/gzip" }
  );

// Download file snapshot
const { data: blob } = await supabase.storage
  .from("sessions")
  .download(`${userId}/${sessionId}/snapshots/${snapshotId}.tar.gz`);
```

### Storage Policies

```sql
-- Users can only access their own files
CREATE POLICY "sessions_storage_select"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'sessions' AND (storage.foldername(name))[1] = auth.uid()::text);

CREATE POLICY "sessions_storage_insert"
  ON storage.objects FOR INSERT
  WITH CHECK (bucket_id = 'sessions' AND (storage.foldername(name))[1] = auth.uid()::text);

CREATE POLICY "sessions_storage_delete"
  ON storage.objects FOR DELETE
  USING (bucket_id = 'sessions' AND (storage.foldername(name))[1] = auth.uid()::text);
```

---

## 8. SQL Utility Functions

```sql
-- ============================================================
-- Migration: 20260331000003_utility_functions.sql
-- ============================================================

-- Increment daily usage (called by Edge Functions)
CREATE OR REPLACE FUNCTION increment_usage(
  p_user_id UUID,
  p_input_tokens INTEGER,
  p_output_tokens INTEGER
)
RETURNS void AS $$
BEGIN
  -- Update profile daily counter
  UPDATE public.profiles
  SET tokens_used_today = tokens_used_today + p_input_tokens + p_output_tokens,
      updated_at = now()
  WHERE id = p_user_id;

  -- Upsert daily usage
  INSERT INTO public.usage_daily (user_id, date, model, input_tokens, output_tokens, request_count)
  VALUES (p_user_id, CURRENT_DATE, 'claude-sonnet-4', p_input_tokens, p_output_tokens, 1)
  ON CONFLICT (user_id, date, model)
  DO UPDATE SET
    input_tokens = usage_daily.input_tokens + EXCLUDED.input_tokens,
    output_tokens = usage_daily.output_tokens + EXCLUDED.output_tokens,
    request_count = usage_daily.request_count + 1;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Get session with messages (efficient join)
CREATE OR REPLACE FUNCTION get_session_with_messages(
  p_session_id UUID,
  p_limit INTEGER DEFAULT 50,
  p_offset INTEGER DEFAULT 0
)
RETURNS TABLE (
  session_data JSONB,
  messages JSONB
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    to_jsonb(s) AS session_data,
    COALESCE(
      jsonb_agg(to_jsonb(m) ORDER BY m.sequence_number)
        FILTER (WHERE m.id IS NOT NULL),
      '[]'::jsonb
    ) AS messages
  FROM public.sessions s
  LEFT JOIN LATERAL (
    SELECT *
    FROM public.messages m2
    WHERE m2.session_id = s.id
    ORDER BY m2.sequence_number DESC
    LIMIT p_limit
    OFFSET p_offset
  ) m ON true
  WHERE s.id = p_session_id
    AND s.user_id = auth.uid()
  GROUP BY s.id;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- Search memories by text (trigram similarity)
CREATE OR REPLACE FUNCTION search_memories(
  p_query TEXT,
  p_limit INTEGER DEFAULT 10,
  p_type TEXT DEFAULT NULL
)
RETURNS TABLE (
  id UUID,
  content TEXT,
  type TEXT,
  category TEXT,
  similarity REAL,
  created_at TIMESTAMPTZ
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    m.id,
    m.content,
    m.type,
    m.category,
    similarity(m.content, p_query) AS similarity,
    m.created_at
  FROM public.memories m
  WHERE m.user_id = auth.uid()
    AND (p_type IS NULL OR m.type = p_type)
    AND m.content % p_query  -- trigram similarity operator
  ORDER BY similarity(m.content, p_query) DESC
  LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- Usage summary for dashboard
CREATE OR REPLACE FUNCTION get_usage_summary(
  p_days INTEGER DEFAULT 30
)
RETURNS TABLE (
  date DATE,
  total_input_tokens BIGINT,
  total_output_tokens BIGINT,
  total_cost_usd NUMERIC,
  total_requests INTEGER,
  total_sessions INTEGER
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    u.date,
    SUM(u.input_tokens)::BIGINT AS total_input_tokens,
    SUM(u.output_tokens)::BIGINT AS total_output_tokens,
    SUM(u.cost_usd) AS total_cost_usd,
    SUM(u.request_count)::INTEGER AS total_requests,
    SUM(u.sessions_count)::INTEGER AS total_sessions
  FROM public.usage_daily u
  WHERE u.user_id = auth.uid()
    AND u.date >= CURRENT_DATE - p_days
  GROUP BY u.date
  ORDER BY u.date DESC;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;
```

---

## 9. Supabase Pricing and Limits

| Feature | Free | Pro ($25/mo) | Team ($599/mo) |
|---------|------|-------------|----------------|
| Database | 500 MB | 8 GB | 16 GB |
| Edge Functions | 500K invocations | 2M invocations | 5M invocations |
| Storage | 1 GB | 100 GB | 200 GB |
| Realtime | 200 concurrent | 500 concurrent | 2000 concurrent |
| Auth | 50K MAU | 100K MAU | Unlimited |
| Bandwidth | 5 GB | 250 GB | 500 GB |
| Daily Backups | No | Yes (7 days) | Yes (14 days) |

### Suitability by Team Size

| Team Size | Recommended Plan | Monthly Cost |
|-----------|-----------------|--------------|
| 1 developer | Free | $0 |
| 2-5 developers | Pro | $25 |
| 5-20 developers | Pro + add-ons | $50-200 |
| 20-100 developers | Team | $599 |
| 100+ developers | Enterprise | Custom |
