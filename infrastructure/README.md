# Claude Code CLI Clone -- Infrastructure Design

## Overview

This document describes the complete infrastructure required to deploy a Claude Code CLI clone -- a terminal-based agentic coding assistant with multi-model LLM support, tool execution sandboxing, multi-agent coordination, MCP server integration, real-time streaming, session persistence, and analytics.

The design is derived from reverse engineering the production Claude Code CLI (Anthropic, ~1,900 files, 512K+ LOC) and maps every runtime component to deployable infrastructure.

## Architecture Summary

```
+-------------------+     +-------------------+     +-------------------+
|   CLI Client      |     |   API Gateway     |     |   LLM Backend     |
|   (Bun + Ink)     |<--->|   (ECS / ACA)     |<--->|   (Anthropic /    |
|   Terminal TUI     |     |   WebSocket/SSE   |     |    Bedrock /      |
+-------------------+     +-------------------+     |    Azure / Local) |
                                |                    +-------------------+
                                |
                    +-----------+-----------+
                    |                       |
             +------v------+        +------v------+
             | Tool Sandbox |        | MCP Server  |
             | (Lambda /    |        | Registry    |
             |  Functions)  |        | (ElastiCache|
             +--------------+        |  / Redis)   |
                                     +-------------+
                    |
             +------v------+
             | Persistence  |
             | (PostgreSQL  |
             |  + S3/Blob)  |
             +--------------+
```

## Core Components

| Component | Purpose | Key Tech |
|-----------|---------|----------|
| CLI Client | Terminal UI, user input, streaming display | Bun, React+Ink, TypeScript |
| API Gateway | Request routing, auth, rate limiting, WebSocket | ECS Fargate / Azure Container Apps |
| LLM Backend | Model inference (streaming) | Anthropic API / Bedrock / Azure OpenAI / Local |
| Tool Sandbox | Isolated execution of Bash, file ops, code | Lambda / Azure Functions / gVisor |
| MCP Registry | Model Context Protocol server discovery & state | Redis / ElastiCache |
| Session Store | Conversation history, agent state, memories | PostgreSQL (Supabase) / RDS |
| Object Storage | File artifacts, snapshots, exports | S3 / Azure Blob |
| Auth Service | OAuth 2.0, API key management, RBAC | Cognito / Azure AD B2C / Supabase Auth |
| Telemetry | Usage metrics, cost tracking, error reporting | OpenTelemetry / CloudWatch / Azure Monitor |
| Analytics | Feature flags, A/B testing, event logging | GrowthBook / Datadog |

## Deployment Options

| Option | Best For | Monthly Cost (10 devs) | Setup Time |
|--------|----------|----------------------|------------|
| [Local Development](./01-local-development.md) | Solo dev, prototyping | $0-50 (API only) | 30 min |
| [AWS Architecture](./02-aws-architecture.md) | Production, enterprise | $800-3,000 | 2-4 hours |
| [Azure Architecture](./03-azure-architecture.md) | Microsoft ecosystem | $900-3,200 | 2-4 hours |
| [Supabase Backend](./04-supabase-backend.md) | Startup, rapid deploy | $25-600 | 1-2 hours |
| [Local GPU + Cloud Hybrid](./01-local-development.md#hybrid) | Cost optimization | $200-800 | 4-8 hours |

## Infrastructure-as-Code

The [terraform/](./terraform/) directory contains full Terraform configurations for AWS deployment:

```bash
cd terraform/
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
terraform init
terraform plan
terraform apply
```

## Document Index

| File | Contents |
|------|----------|
| [01-local-development.md](./01-local-development.md) | Local dev setup, model options, hardware requirements |
| [02-aws-architecture.md](./02-aws-architecture.md) | AWS deployment with ECS, Lambda, Bedrock |
| [03-azure-architecture.md](./03-azure-architecture.md) | Azure deployment with Container Apps, Functions |
| [04-supabase-backend.md](./04-supabase-backend.md) | Supabase schema, RLS, Edge Functions |
| [05-cost-analysis.md](./05-cost-analysis.md) | Comprehensive cost breakdown across all options |
| [06-architecture-diagram.md](./06-architecture-diagram.md) | ASCII architecture and flow diagrams |
| [terraform/](./terraform/) | IaC for AWS deployment |

## Quick Start Decision Tree

```
Do you need multi-user support?
  NO  --> Local Development (01)
  YES --> Do you use AWS already?
            YES --> AWS Architecture (02) + Terraform
            NO  --> Do you use Azure?
                      YES --> Azure Architecture (03)
                      NO  --> Supabase Backend (04)

Do you want to avoid API costs?
  YES --> Local GPU setup (01, Local Models section)
  NO  --> Anthropic API direct (cheapest per-token)

Budget constraint?
  < $100/mo  --> Supabase Free + Anthropic API
  < $1000/mo --> Supabase Pro + Anthropic API
  < $5000/mo --> AWS/Azure full deployment
  > $5000/mo --> Multi-region with local GPU inference
```

## Security Considerations

- All tool execution MUST run in sandboxed environments (Lambda/gVisor/Firecracker)
- API keys stored in secrets managers (AWS SSM, Azure Key Vault, Supabase Vault)
- Network traffic encrypted in transit (TLS 1.3)
- Session data encrypted at rest (AES-256)
- RLS policies enforce per-user data isolation
- OAuth 2.0 PKCE flow for CLI authentication
- Rate limiting at API gateway level
- Audit logging for all tool executions

## Performance Targets

| Metric | Target | Notes |
|--------|--------|-------|
| Time to first token | < 500ms | Streaming SSE/WebSocket |
| Tool execution latency | < 2s | Cold start < 5s (Lambda) |
| Session restore | < 1s | Cached in Redis |
| MCP server connect | < 3s | Connection pooling |
| Concurrent users per node | 50-100 | WebSocket connections |
| API gateway throughput | 10,000 req/s | Per region |
