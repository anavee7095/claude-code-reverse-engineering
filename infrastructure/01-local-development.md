# 01 -- Local Development Setup

## Overview

Local development can run entirely on a single machine with either cloud API inference or local GPU inference. This document covers both scenarios plus a hybrid approach.

---

## 1. Model Options

### 1.1 Cloud API (Recommended for Development)

| Provider | Model | Input $/M | Output $/M | Context | Tool Use |
|----------|-------|-----------|------------|---------|----------|
| **Anthropic Direct** | Claude Opus 4 | $15.00 | $75.00 | 200K | Full |
| Anthropic Direct | Claude Sonnet 4 | $3.00 | $15.00 | 200K | Full |
| Anthropic Direct | Claude Haiku 3.5 | $0.80 | $4.00 | 200K | Full |
| AWS Bedrock | Claude Opus 4 | $18.00 | $90.00 | 200K | Full |
| AWS Bedrock | Claude Sonnet 4 | $3.60 | $18.00 | 200K | Full |
| Azure OpenAI | GPT-4o | $2.50 | $10.00 | 128K | Full |
| Azure OpenAI | GPT-4.1 | $2.00 | $8.00 | 1M | Full |
| OpenAI Direct | GPT-4o | $2.50 | $10.00 | 128K | Full |
| Google | Gemini 2.5 Pro | $1.25 | $10.00 | 1M | Full |

**Setup:**
```bash
# Anthropic Direct (recommended)
export ANTHROPIC_API_KEY="sk-ant-..."

# AWS Bedrock
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_REGION="us-east-1"

# Azure OpenAI
export AZURE_OPENAI_ENDPOINT="https://your-resource.openai.azure.com"
export AZURE_OPENAI_API_KEY="..."
```

### 1.2 Local Models (Ollama)

**Recommended models for tool-use capable coding:**

| Model | Parameters | VRAM Required | Tool Use | Coding Quality |
|-------|-----------|---------------|----------|----------------|
| **Qwen2.5-Coder-32B-Instruct** | 32B | 20 GB (Q4) | Good | Excellent |
| **DeepSeek-V3** | 671B MoE | 40 GB (Q4) | Good | Excellent |
| **Llama-3.3-70B-Instruct** | 70B | 42 GB (Q4) | Good | Very Good |
| Codestral-25.01 | 22B | 14 GB (Q4) | Limited | Good |
| Qwen2.5-Coder-7B-Instruct | 7B | 5 GB (Q4) | Basic | Fair |
| DeepSeek-Coder-V2-Lite | 16B | 10 GB (Q4) | Basic | Good |

**Minimum requirement for tool use: 32B+ parameter model** -- smaller models cannot reliably follow the structured tool-calling format required by the agent loop.

**Ollama setup:**
```bash
# Install Ollama
curl -fsSL https://ollama.ai/install.sh | sh

# Pull recommended models
ollama pull qwen2.5-coder:32b-instruct-q4_K_M
ollama pull deepseek-v3:latest
ollama pull llama3.3:70b-instruct-q4_K_M

# Verify
ollama list
curl http://localhost:11434/api/tags
```

**Ollama API endpoint:** `http://localhost:11434/v1` (OpenAI-compatible)

### 1.3 LM Studio

LM Studio provides a GUI for managing and running local models with an OpenAI-compatible server.

```bash
# Download from https://lmstudio.ai
# Load model via GUI
# Server starts at http://localhost:1234/v1

export LM_STUDIO_ENDPOINT="http://localhost:1234/v1"
export LM_STUDIO_API_KEY="lm-studio"  # placeholder, not validated
```

### 1.4 vLLM (Production-Grade Local Inference)

For multi-GPU setups or when serving to multiple developers on a LAN:

```bash
# Install vLLM
pip install vllm

# Serve a model with tool calling support
vllm serve Qwen/Qwen2.5-Coder-32B-Instruct \
  --host 0.0.0.0 \
  --port 8000 \
  --tensor-parallel-size 2 \
  --max-model-len 32768 \
  --enable-auto-tool-choice \
  --tool-call-parser hermes \
  --gpu-memory-utilization 0.9

# Or for DeepSeek-V3 on multi-GPU
vllm serve deepseek-ai/DeepSeek-V3 \
  --host 0.0.0.0 \
  --port 8000 \
  --tensor-parallel-size 4 \
  --pipeline-parallel-size 2 \
  --max-model-len 65536 \
  --enable-auto-tool-choice \
  --tool-call-parser hermes
```

**vLLM endpoint:** `http://localhost:8000/v1` (OpenAI-compatible)

---

## 2. Hardware Requirements

### 2.1 Cloud API Only (Minimum)

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| CPU | 2 cores | 4+ cores |
| RAM | 4 GB | 8 GB |
| Disk | 1 GB | 5 GB |
| GPU | None | None |
| Network | 10 Mbps | 50+ Mbps |

### 2.2 Local Model Inference

| Model Size | GPU VRAM | System RAM | Disk | Example GPU |
|-----------|----------|------------|------|-------------|
| 7B (Q4) | 5 GB | 16 GB | 10 GB | RTX 3060 12GB |
| 14-22B (Q4) | 12-16 GB | 32 GB | 20 GB | RTX 4070 Ti 16GB |
| **32B (Q4)** | **20 GB** | **32 GB** | **25 GB** | **RTX 4090 24GB** |
| **70B (Q4)** | **42 GB** | **64 GB** | **50 GB** | **2x RTX 4090 / A6000 48GB** |
| 671B MoE (Q4) | **80+ GB** | **128 GB** | **400 GB** | **A100 80GB / 2x H100** |

### 2.3 Multi-Developer LAN Server

For serving local models to a team of 2-5 developers:

| Component | Specification | Cost (Approx.) |
|-----------|--------------|-----------------|
| GPU | 2x RTX 4090 24GB | $3,200 |
| CPU | AMD Ryzen 9 7950X (16C/32T) | $550 |
| RAM | 128 GB DDR5-5600 | $350 |
| NVMe | 2 TB Gen4 | $150 |
| PSU | 1600W Platinum | $350 |
| Case + Cooling | Full tower, AIO + GPU coolers | $400 |
| **Total** | | **~$5,000** |

This server can run Qwen2.5-Coder-32B at ~40 tokens/sec or Llama-3.3-70B at ~20 tokens/sec, supporting 2-3 concurrent coding sessions.

---

## 3. Docker Compose for Local Dev Stack

### 3.1 Full Development Stack

```yaml
# docker-compose.yml
version: "3.8"

services:
  # ---- PostgreSQL (session persistence) ----
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: claude_code
      POSTGRES_USER: claude
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-localdev123}
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./init-db.sql:/docker-entrypoint-initdb.d/01-init.sql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U claude -d claude_code"]
      interval: 5s
      timeout: 5s
      retries: 5

  # ---- Redis (MCP state, session cache, rate limiting) ----
  redis:
    image: redis:7-alpine
    command: redis-server --appendonly yes --maxmemory 256mb --maxmemory-policy allkeys-lru
    ports:
      - "6379:6379"
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5

  # ---- MinIO (S3-compatible object storage) ----
  minio:
    image: minio/minio:latest
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: ${MINIO_ACCESS_KEY:-minioadmin}
      MINIO_ROOT_PASSWORD: ${MINIO_SECRET_KEY:-minioadmin}
    ports:
      - "9000:9000"   # API
      - "9001:9001"   # Console
    volumes:
      - minio_data:/data
    healthcheck:
      test: ["CMD", "mc", "ready", "local"]
      interval: 5s
      timeout: 5s
      retries: 5

  # ---- API Gateway (the main application) ----
  api-gateway:
    build:
      context: .
      dockerfile: Dockerfile.api
    environment:
      DATABASE_URL: postgresql://claude:${POSTGRES_PASSWORD:-localdev123}@postgres:5432/claude_code
      REDIS_URL: redis://redis:6379
      S3_ENDPOINT: http://minio:9000
      S3_ACCESS_KEY: ${MINIO_ACCESS_KEY:-minioadmin}
      S3_SECRET_KEY: ${MINIO_SECRET_KEY:-minioadmin}
      S3_BUCKET: claude-code-sessions
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY}
      LLM_PROVIDER: ${LLM_PROVIDER:-anthropic}        # anthropic | ollama | vllm | lmstudio
      LOCAL_MODEL_ENDPOINT: ${LOCAL_MODEL_ENDPOINT:-}  # http://host.docker.internal:11434/v1
      JWT_SECRET: ${JWT_SECRET:-dev-secret-change-in-production}
      NODE_ENV: development
    ports:
      - "3100:3100"   # HTTP/WebSocket API
      - "3101:3101"   # gRPC (telemetry)
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3100/health"]
      interval: 10s
      timeout: 5s
      retries: 3

  # ---- Tool Sandbox (isolated execution environment) ----
  tool-sandbox:
    build:
      context: .
      dockerfile: Dockerfile.sandbox
    environment:
      API_GATEWAY_URL: http://api-gateway:3100
      MAX_EXECUTION_TIME: 300  # seconds
      MAX_MEMORY_MB: 2048
    security_opt:
      - seccomp:unconfined  # required for gVisor/sandbox
    tmpfs:
      - /tmp:size=1G
      - /workspace:size=5G
    deploy:
      resources:
        limits:
          cpus: "4.0"
          memory: 4G
        reservations:
          cpus: "1.0"
          memory: 1G

  # ---- Telemetry Collector (OpenTelemetry) ----
  otel-collector:
    image: otel/opentelemetry-collector-contrib:0.96.0
    command: ["--config=/etc/otel-collector-config.yaml"]
    volumes:
      - ./otel-collector-config.yaml:/etc/otel-collector-config.yaml
    ports:
      - "4317:4317"   # gRPC OTLP
      - "4318:4318"   # HTTP OTLP
      - "8888:8888"   # Prometheus metrics
    depends_on:
      - api-gateway

  # ---- Jaeger (trace visualization, optional) ----
  jaeger:
    image: jaegertracing/all-in-one:1.54
    ports:
      - "16686:16686"  # UI
      - "14250:14250"  # gRPC
    environment:
      COLLECTOR_OTLP_ENABLED: "true"

volumes:
  postgres_data:
  redis_data:
  minio_data:
```

### 3.2 Docker Compose Environment File

```bash
# .env (copy to .env.local and edit)

# LLM Provider: anthropic | ollama | vllm | lmstudio | bedrock | azure
LLM_PROVIDER=anthropic

# Anthropic API (required if LLM_PROVIDER=anthropic)
ANTHROPIC_API_KEY=sk-ant-api03-...

# Local model endpoint (required if LLM_PROVIDER=ollama|vllm|lmstudio)
LOCAL_MODEL_ENDPOINT=http://host.docker.internal:11434/v1
LOCAL_MODEL_NAME=qwen2.5-coder:32b-instruct-q4_K_M

# Database
POSTGRES_PASSWORD=localdev123

# Object storage
MINIO_ACCESS_KEY=minioadmin
MINIO_SECRET_KEY=minioadmin

# Auth
JWT_SECRET=change-this-in-production-use-openssl-rand-base64-32
```

### 3.3 Supplementary Docker Files

**Dockerfile.api:**
```dockerfile
FROM oven/bun:1.1-alpine AS builder
WORKDIR /app
COPY package.json bun.lockb ./
RUN bun install --frozen-lockfile
COPY . .
RUN bun run build

FROM oven/bun:1.1-alpine
WORKDIR /app
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./
EXPOSE 3100 3101
CMD ["bun", "run", "dist/server/index.js"]
```

**Dockerfile.sandbox:**
```dockerfile
FROM ubuntu:24.04

# Install common development tools
RUN apt-get update && apt-get install -y \
    git curl wget jq ripgrep \
    python3 python3-pip \
    nodejs npm \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install Bun
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:$PATH"

# Create sandbox user (non-root execution)
RUN useradd -m -s /bin/bash sandbox
USER sandbox
WORKDIR /workspace

COPY --chown=sandbox:sandbox sandbox-runner.sh /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/sandbox-runner.sh"]
```

### 3.4 OpenTelemetry Collector Config

```yaml
# otel-collector-config.yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch:
    timeout: 10s
    send_batch_size: 1024
  memory_limiter:
    check_interval: 5s
    limit_mib: 256

exporters:
  jaeger:
    endpoint: jaeger:14250
    tls:
      insecure: true
  prometheus:
    endpoint: 0.0.0.0:8888

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [jaeger]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [prometheus]
```

---

## 4. Running Locally

### 4.1 Quick Start (Cloud API)

```bash
# 1. Clone and install
git clone <repo-url>
cd claude-code-clone
bun install

# 2. Set API key
export ANTHROPIC_API_KEY="sk-ant-..."

# 3. Start infrastructure
docker compose up -d postgres redis

# 4. Run database migrations
bun run db:migrate

# 5. Start the CLI
bun run dev
```

### 4.2 Quick Start (Local Model)

```bash
# 1. Start Ollama with a model
ollama serve &
ollama pull qwen2.5-coder:32b-instruct-q4_K_M

# 2. Start infrastructure
docker compose up -d postgres redis

# 3. Configure local model
export LLM_PROVIDER=ollama
export LOCAL_MODEL_ENDPOINT=http://localhost:11434/v1
export LOCAL_MODEL_NAME=qwen2.5-coder:32b-instruct-q4_K_M

# 4. Start the CLI
bun run dev
```

### 4.3 Full Stack (All Services)

```bash
# Start everything
docker compose up -d

# Verify
docker compose ps
curl http://localhost:3100/health
curl http://localhost:9001  # MinIO console

# View logs
docker compose logs -f api-gateway
```

---

## 5. Hybrid Setup (Local GPU + Cloud API) {#hybrid}

Use a local model for routine tasks (file reading, code search, simple edits) and route complex reasoning to a cloud API. This reduces API costs by 60-80%.

### Architecture

```
CLI Client
  |
  +---> Router (based on task complexity)
          |
          +---> Local Ollama (Qwen2.5-32B)   -- simple tool calls, file ops
          |         Cost: $0 (electricity)
          |
          +---> Anthropic API (Sonnet 4)      -- complex reasoning, debugging
                    Cost: $3/$15 per M tokens
```

### Configuration

```typescript
// model-router.ts
interface ModelRoute {
  provider: "local" | "cloud";
  model: string;
  endpoint: string;
}

const ROUTES: Record<string, ModelRoute> = {
  // Simple tasks -> local model
  "file_read":     { provider: "local", model: "qwen2.5-coder:32b", endpoint: "http://localhost:11434/v1" },
  "glob":          { provider: "local", model: "qwen2.5-coder:32b", endpoint: "http://localhost:11434/v1" },
  "grep":          { provider: "local", model: "qwen2.5-coder:32b", endpoint: "http://localhost:11434/v1" },
  "bash_simple":   { provider: "local", model: "qwen2.5-coder:32b", endpoint: "http://localhost:11434/v1" },

  // Complex tasks -> cloud API
  "reasoning":     { provider: "cloud", model: "claude-sonnet-4-20250514", endpoint: "https://api.anthropic.com" },
  "code_generate": { provider: "cloud", model: "claude-sonnet-4-20250514", endpoint: "https://api.anthropic.com" },
  "debugging":     { provider: "cloud", model: "claude-sonnet-4-20250514", endpoint: "https://api.anthropic.com" },
  "architecture":  { provider: "cloud", model: "claude-opus-4-20250115",   endpoint: "https://api.anthropic.com" },
};
```

### Cost Savings Estimate (Solo Developer)

| Usage Pattern | Cloud Only | Hybrid | Savings |
|---------------|-----------|--------|---------|
| Light (50K tokens/day) | $45/mo | $15/mo | 67% |
| Medium (200K tokens/day) | $180/mo | $55/mo | 69% |
| Heavy (500K tokens/day) | $450/mo | $120/mo | 73% |

*Assumes 70% of requests are simple tool calls routed to local model.*

---

## 6. Development Tools and Debugging

### 6.1 Useful Commands

```bash
# Database inspection
docker compose exec postgres psql -U claude -d claude_code

# Redis inspection
docker compose exec redis redis-cli
> KEYS mcp:*
> GET session:<session-id>

# View telemetry traces
open http://localhost:16686  # Jaeger UI

# Monitor resource usage
docker stats

# Tail all logs
docker compose logs -f --tail=50
```

### 6.2 VS Code Integration

```json
// .vscode/launch.json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Debug CLI",
      "type": "bun",
      "request": "launch",
      "program": "${workspaceFolder}/src/main.tsx",
      "env": {
        "ANTHROPIC_API_KEY": "${env:ANTHROPIC_API_KEY}",
        "DATABASE_URL": "postgresql://claude:localdev123@localhost:5432/claude_code"
      }
    }
  ]
}
```

### 6.3 Testing Tool Sandbox Locally

```bash
# Test sandbox isolation
docker compose exec tool-sandbox bash -c "
  whoami          # should be 'sandbox'
  cat /etc/passwd # readable
  apt install vim # should fail (no sudo)
  timeout 5 bash -c 'while true; do :; done'  # CPU limit test
"
```
