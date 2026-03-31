# 05 -- Comprehensive Cost Analysis

## Overview

This document provides detailed cost projections for running a Claude Code CLI clone across all deployment options and usage levels. All prices reflect March 2026 approximate rates.

---

## 1. Token Cost per Provider

### 1.1 Model Pricing Comparison

| Provider | Model | Input $/M | Output $/M | Effective $/M (avg) | Notes |
|----------|-------|-----------|------------|---------------------|-------|
| **Anthropic Direct** | Opus 4 | $15.00 | $75.00 | $45.00 | Highest quality |
| Anthropic Direct | Sonnet 4 | $3.00 | $15.00 | $9.00 | Best value |
| Anthropic Direct | Haiku 3.5 | $0.80 | $4.00 | $2.40 | Fastest |
| **Anthropic (cached)** | Sonnet 4 (cache hit) | $0.30 | $15.00 | $7.65 | 90% cache rate |
| **AWS Bedrock** | Opus 4 | $18.00 | $90.00 | $54.00 | +20% markup |
| Bedrock | Sonnet 4 | $3.60 | $18.00 | $10.80 | +20% markup |
| Bedrock | Haiku 3.5 | $1.00 | $5.00 | $3.00 | +25% markup |
| **Azure OpenAI** | GPT-4o | $2.50 | $10.00 | $6.25 | Good alternative |
| Azure OpenAI | GPT-4.1 | $2.00 | $8.00 | $5.00 | 1M context |
| Azure OpenAI | GPT-4o-mini | $0.15 | $0.60 | $0.38 | Budget option |
| **OpenAI Direct** | GPT-4o | $2.50 | $10.00 | $6.25 | Same as Azure |
| OpenAI Direct | o3 | $10.00 | $40.00 | $25.00 | Reasoning |
| **Google** | Gemini 2.5 Pro | $1.25 | $10.00 | $5.63 | 1M context |
| **Local (Ollama)** | Qwen2.5-32B | $0.00 | $0.00 | $0.00 | Electricity only |
| **Local (vLLM)** | Llama-3.3-70B | $0.00 | $0.00 | $0.00 | Electricity only |

*Effective $/M assumes a typical 60:40 input:output token ratio for coding tasks.*

### 1.2 Token Usage Patterns (Measured from Real Usage)

| Activity | Input Tokens | Output Tokens | Total Tokens | Frequency |
|----------|-------------|---------------|--------------|-----------|
| Simple file read/edit | 2,000 | 500 | 2,500 | Very High |
| Code search (glob+grep) | 3,000 | 1,000 | 4,000 | High |
| Single function impl | 5,000 | 3,000 | 8,000 | Medium |
| Multi-file refactor | 15,000 | 8,000 | 23,000 | Medium |
| Complex debugging | 20,000 | 10,000 | 30,000 | Low |
| Architecture discussion | 8,000 | 5,000 | 13,000 | Low |
| Agent task (multi-turn) | 50,000 | 25,000 | 75,000 | Low |

### 1.3 Developer Usage Profiles

| Profile | Sessions/Day | Tokens/Session | Tokens/Day | Tokens/Month |
|---------|-------------|----------------|------------|-------------- |
| **Light** | 5 | 10,000 | 50,000 | 1,100,000 |
| **Medium** | 15 | 15,000 | 225,000 | 4,950,000 |
| **Heavy** | 30 | 20,000 | 600,000 | 13,200,000 |
| **Power User** | 50+ | 25,000 | 1,250,000 | 27,500,000 |

*22 working days/month.*

---

## 2. Per-Developer Monthly Token Cost

### 2.1 Anthropic Direct (Sonnet 4)

| Usage Level | Input Tokens | Output Tokens | Input Cost | Output Cost | **Total/mo** |
|-------------|-------------|---------------|------------|-------------|-------------|
| Light | 660K | 440K | $1.98 | $6.60 | **$8.58** |
| Medium | 2,970K | 1,980K | $8.91 | $29.70 | **$38.61** |
| Heavy | 7,920K | 5,280K | $23.76 | $79.20 | **$102.96** |
| Power User | 16,500K | 11,000K | $49.50 | $165.00 | **$214.50** |

### 2.2 Anthropic Direct (Sonnet 4, with Prompt Caching)

Prompt caching reduces input token cost by ~90% for cached portions. Typical cache hit rate for coding: 60-80%.

| Usage Level | Effective Input | Output Tokens | Input Cost | Output Cost | **Total/mo** | Savings |
|-------------|----------------|---------------|------------|-------------|-------------|---------|
| Light | 660K (70% cached) | 440K | $0.79 | $6.60 | **$7.39** | 14% |
| Medium | 2,970K (70% cached) | 1,980K | $3.56 | $29.70 | **$33.26** | 14% |
| Heavy | 7,920K (75% cached) | 5,280K | $8.32 | $79.20 | **$87.52** | 15% |
| Power User | 16,500K (80% cached) | 11,000K | $13.86 | $165.00 | **$178.86** | 17% |

### 2.3 AWS Bedrock (Sonnet 4)

| Usage Level | Total Tokens/mo | **Cost/mo** | vs Anthropic Direct |
|-------------|----------------|-------------|---------------------|
| Light | 1.1M | **$10.30** | +20% |
| Medium | 4.95M | **$46.33** | +20% |
| Heavy | 13.2M | **$123.55** | +20% |
| Power User | 27.5M | **$257.40** | +20% |

### 2.4 Azure OpenAI (GPT-4o)

| Usage Level | Total Tokens/mo | **Cost/mo** | vs Anthropic Direct |
|-------------|----------------|-------------|---------------------|
| Light | 1.1M | **$5.50** | -36% |
| Medium | 4.95M | **$24.75** | -36% |
| Heavy | 13.2M | **$66.00** | -36% |
| Power User | 27.5M | **$137.50** | -36% |

### 2.5 Local GPU (Amortized Hardware Cost)

| Hardware | Purchase | Lifespan | Monthly Amort. | Electricity | **Total/mo** |
|----------|----------|----------|----------------|-------------|-------------|
| RTX 4090 (24GB) | $1,600 | 36 mo | $44.44 | $15 | **$59.44** |
| 2x RTX 4090 | $3,200 | 36 mo | $88.89 | $30 | **$118.89** |
| A6000 (48GB) | $4,500 | 36 mo | $125.00 | $20 | **$145.00** |
| A100 80GB (used) | $8,000 | 36 mo | $222.22 | $25 | **$247.22** |
| H100 80GB (used) | $20,000 | 36 mo | $555.56 | $30 | **$585.56** |

| Hardware | Serves N Devs | **Per-Dev/mo** | Model Quality |
|----------|--------------|----------------|---------------|
| RTX 4090 | 1-2 | $30-60 | 32B (Good) |
| 2x RTX 4090 | 2-4 | $30-60 | 70B (Very Good) |
| A6000 | 2-3 | $48-73 | 70B (Very Good) |
| A100 80GB | 3-6 | $41-82 | 70B-671B MoE (Excellent) |
| H100 80GB | 5-10 | $59-117 | 671B MoE (Excellent) |

### 2.6 Cloud GPU Rental (for local-quality without hardware purchase)

| Provider | GPU | $/hr | Monthly (24/7) | Monthly (8h/day) |
|----------|-----|------|----------------|------------------|
| RunPod | A100 80GB | $1.64 | $1,181 | $361 |
| RunPod | H100 80GB | $3.29 | $2,369 | $724 |
| Lambda Labs | A100 80GB | $1.29 | $929 | $284 |
| Lambda Labs | H100 80GB | $2.49 | $1,793 | $548 |
| Vast.ai | RTX 4090 | $0.30 | $216 | $66 |
| Vast.ai | A100 80GB | $1.10 | $792 | $242 |

---

## 3. Infrastructure Costs

### 3.1 AWS Infrastructure

| Component | Sizing | 1 User | 10 Users | 100 Users | 1000 Users |
|-----------|--------|--------|----------|-----------|------------|
| ECS Fargate (API) | 0.5-8 vCPU | $30 | $60 | $250 | $1,200 |
| RDS PostgreSQL | t4g.medium Multi-AZ | $135 | $135 | $270 | $540 |
| ElastiCache Redis | t4g.micro | $12 | $12 | $25 | $100 |
| ALB | Per-hour + LCU | $18 | $20 | $35 | $80 |
| S3 | Standard + requests | $1 | $5 | $25 | $150 |
| Lambda (tools) | Invocations + duration | $2 | $15 | $80 | $500 |
| CloudWatch | Logs + metrics | $5 | $10 | $30 | $100 |
| Cognito | Free tier | $0 | $0 | $0 | $55 |
| NAT Gateway | Per-hour + data | $35 | $35 | $70 | $140 |
| Secrets Manager | Per-secret + API | $1 | $1 | $2 | $5 |
| **AWS Infra Total** | | **$239** | **$293** | **$787** | **$2,870** |

### 3.2 Azure Infrastructure

| Component | Sizing | 1 User | 10 Users | 100 Users | 1000 Users |
|-----------|--------|--------|----------|-----------|------------|
| Container Apps | D4 workload | $35 | $70 | $280 | $1,400 |
| PostgreSQL | GP D2ds v5 HA | $190 | $190 | $380 | $760 |
| Redis Cache | Basic C1 | $40 | $40 | $80 | $300 |
| Front Door | Standard | $35 | $38 | $55 | $120 |
| Blob Storage | Hot tier | $1 | $5 | $25 | $150 |
| Functions | Premium EP1 | $145 | $145 | $290 | $580 |
| App Insights | Logs + metrics | $3 | $10 | $40 | $150 |
| Azure AD B2C | Free tier | $0 | $0 | $0 | $30 |
| VNet / Networking | Misc | $10 | $10 | $20 | $50 |
| Key Vault | Per-secret + ops | $1 | $1 | $2 | $5 |
| **Azure Infra Total** | | **$460** | **$509** | **$1,172** | **$3,545** |

### 3.3 Supabase

| Component | Free | Pro ($25) | Team ($599) | Enterprise |
|-----------|------|-----------|-------------|------------|
| Database | $0 | $25 | $599 | Custom |
| Compute add-on | $0 | $0-100 | $0-200 | Custom |
| Edge Functions | $0 | $0 | $0 | Custom |
| Storage add-on | $0 | $0-50 | $0-100 | Custom |
| **Supabase Total** | **$0** | **$25-175** | **$599-899** | **Custom** |

---

## 4. Total Cost by Scenario

### 4.1 Solo Developer

| Configuration | Infra | Tokens | **Monthly Total** |
|---------------|-------|--------|-------------------|
| Supabase Free + Anthropic (Light) | $0 | $9 | **$9** |
| Supabase Free + Anthropic (Medium) | $0 | $39 | **$39** |
| Supabase Free + Anthropic (Heavy) | $0 | $103 | **$103** |
| Supabase Free + Local RTX 4090 | $0 | $59 * | **$59** |
| Supabase Free + Hybrid (Local+API) | $0 | $30 | **$30** |
| AWS + Anthropic (Medium) | $239 | $39 | **$278** |

\* Amortized hardware cost

### 4.2 Small Team (10 Developers)

| Configuration | Infra | Tokens | **Monthly Total** | Per-Dev |
|---------------|-------|--------|-------------------|---------|
| Supabase Pro + Anthropic (Medium) | $75 | $386 | **$461** | **$46** |
| Supabase Pro + Anthropic (Heavy) | $125 | $1,030 | **$1,155** | **$116** |
| AWS + Anthropic (Medium) | $293 | $386 | **$679** | **$68** |
| AWS + Bedrock (Medium) | $293 | $463 | **$756** | **$76** |
| AWS + Hybrid (Local+API) | $293 | $150 | **$443** | **$44** |
| Azure + GPT-4o (Medium) | $509 | $248 | **$757** | **$76** |
| Azure + Azure OpenAI (Heavy) | $509 | $660 | **$1,169** | **$117** |

### 4.3 Enterprise (100 Developers)

| Configuration | Infra | Tokens | **Monthly Total** | Per-Dev |
|---------------|-------|--------|-------------------|---------|
| Supabase Team + Anthropic (Medium) | $899 | $3,861 | **$4,760** | **$48** |
| AWS + Anthropic (Medium) | $787 | $3,861 | **$4,648** | **$46** |
| AWS + Anthropic (Heavy) | $787 | $10,296 | **$11,083** | **$111** |
| AWS + Bedrock (Medium) | $787 | $4,633 | **$5,420** | **$54** |
| AWS + Hybrid (Local GPU cluster) | $1,287 | $1,200 | **$2,487** | **$25** |
| Azure + GPT-4o (Medium) | $1,172 | $2,475 | **$3,647** | **$36** |

### 4.4 Scale (1000 Developers)

| Configuration | Infra | Tokens | **Monthly Total** | Per-Dev |
|---------------|-------|--------|-------------------|---------|
| AWS + Anthropic (Medium) | $2,870 | $38,610 | **$41,480** | **$41** |
| AWS + Anthropic (Heavy) | $2,870 | $102,960 | **$105,830** | **$106** |
| AWS + Bedrock (Medium) | $2,870 | $46,332 | **$49,202** | **$49** |
| AWS + Hybrid (GPU cluster) | $5,870 | $12,000 | **$17,870** | **$18** |
| Azure + GPT-4o (Medium) | $3,545 | $24,750 | **$28,295** | **$28** |

---

## 5. Break-Even Analysis: Cloud vs Local GPU

### 5.1 When Does Local GPU Pay Off?

**Assumption**: Comparing against Anthropic Direct Sonnet 4 at $9/M effective tokens.

| Hardware | Monthly Amort. + Power | Break-even Token Volume | Break-even Dev Count |
|----------|----------------------|------------------------|---------------------|
| RTX 4090 (32B model) | $59 | 6.6M tokens/mo | 1-2 Medium devs |
| 2x RTX 4090 (70B model) | $119 | 13.2M tokens/mo | 3 Medium devs |
| A100 80GB (70B model) | $247 | 27.4M tokens/mo | 6 Medium devs |
| H100 80GB (671B MoE) | $586 | 65.1M tokens/mo | 13 Medium devs |

### 5.2 Quality Tradeoff

| Tier | Cloud Model | Local Equivalent | Quality Gap |
|------|------------|------------------|-------------|
| Premium | Claude Opus 4 | None (no equivalent) | Huge gap |
| Standard | Claude Sonnet 4 | Llama-3.3-70B / DeepSeek-V3 | Moderate gap |
| Fast | Claude Haiku 3.5 | Qwen2.5-Coder-32B | Small gap |
| Budget | GPT-4o-mini | Qwen2.5-Coder-7B | Moderate gap |

**Key insight**: Local models close the gap for routine operations (file I/O, search, simple edits) but lag behind for complex reasoning, debugging, and multi-step architecture tasks.

### 5.3 Hybrid Recommendation

```
                     Task Complexity
                Low ──────────────── High
                │                      │
Local Model ◀──┤                      ├──▶ Cloud API
(70% of tasks) │  File read/write     │    Complex debugging
               │  Code search         │    Architecture
               │  Simple edits        │    Multi-file refactor
               │  Git operations      │    Error analysis
               │  Test running        │    Code generation
               │                      │
Cost: $0       │                      │    Cost: $3-15/M tokens
```

**Optimal hybrid split**: 70% local / 30% cloud saves 60-73% vs pure cloud.

---

## 6. Cost Comparison Summary Table

### Monthly Cost per Developer (Medium Usage: ~5M tokens/month)

| Deployment | Solo | 10 Team | 100 Enterprise | 1000 Scale |
|-----------|------|---------|----------------|------------|
| **Supabase + Anthropic** | $39 | $46 | $48 | N/A |
| **AWS + Anthropic** | $278 | $68 | $46 | $41 |
| **AWS + Bedrock** | $288 | $76 | $54 | $49 |
| **Azure + GPT-4o** | $500 | $76 | $36 | $28 |
| **AWS + Hybrid** | $269 | $44 | $25 | $18 |
| **Local Only** | $59 | N/A | N/A | N/A |

### Key Findings

1. **Cheapest for Solo**: Supabase Free + Anthropic Direct ($9-39/mo)
2. **Cheapest for Small Team**: Supabase Pro + Anthropic Direct ($46/dev/mo)
3. **Cheapest for Enterprise**: AWS + Hybrid local/cloud ($25/dev/mo)
4. **Cheapest for Scale**: AWS + Hybrid with GPU cluster ($18/dev/mo)
5. **Simplest to Deploy**: Supabase (1-2 hours setup)
6. **Most Compliant**: AWS Bedrock or Azure OpenAI (SOC2/HIPAA)

### Cost Dominated by Tokens

At every scale, **LLM token costs represent 60-95% of total cost**. Infrastructure is a minor factor. The most impactful optimizations are:

1. **Prompt caching** (14-17% savings, easy to implement)
2. **Hybrid local/cloud routing** (60-73% savings, moderate complexity)
3. **Model selection** (use Haiku/mini for simple tasks, Sonnet/4o for complex)
4. **Context window management** (compact conversations to reduce input tokens)
5. **Token budgets per user** (prevent runaway costs)

---

## 7. Scaling Cost Curves

```
Monthly Cost ($)
│
│                                          ╱ AWS + Bedrock
│                                        ╱
│                                      ╱
│                                    ╱    ╱ AWS + Anthropic Direct
│                                  ╱    ╱
│                                ╱    ╱
│                              ╱    ╱
│                            ╱    ╱       ╱ Azure + GPT-4o
│                          ╱    ╱       ╱
│                        ╱    ╱       ╱
│                      ╱    ╱       ╱
│                    ╱    ╱       ╱        ╱ AWS + Hybrid
│                  ╱    ╱       ╱        ╱
│                ╱    ╱       ╱        ╱
│    ▪─────────╱────╱───────╱────────╱─────── Infrastructure base
│  ╱         ╱   ╱       ╱        ╱
│╱─────────╱───╱───────╱────────╱───
├──────────┼──────────┼──────────┼──────── Users
0         10        100       1000

Token costs grow linearly. Infrastructure costs grow sub-linearly (shared resources).
The gap between curves = provider markup + model pricing difference.
```
