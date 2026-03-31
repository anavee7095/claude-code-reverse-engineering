# 02 -- AWS Architecture

## Overview

Full production deployment on AWS designed for multi-tenant, enterprise-grade usage. Uses managed services to minimize operational overhead while maintaining security isolation for tool execution.

---

## 1. Architecture Diagram

```
                        ┌──────────────────────────────────────────────┐
                        │                  AWS Cloud                   │
                        │                                              │
  CLI Client ──────────>│  ┌──────────────┐     ┌──────────────────┐  │
  (WebSocket/SSE)       │  │   ALB/NLB    │────>│  ECS Fargate     │  │
                        │  │  (Public)    │     │  API Gateway     │  │
                        │  └──────────────┘     │  Cluster         │  │
                        │                       │  ┌────────────┐  │  │
                        │                       │  │ api-gw x3  │  │  │
                        │                       │  └─────┬──────┘  │  │
                        │                       └────────┼─────────┘  │
                        │                                │            │
                        │        ┌───────────────────────┼──────┐     │
                        │        │                       │      │     │
                        │  ┌─────▼──────┐  ┌─────────┐  │  ┌───▼──┐  │
                        │  │  Bedrock   │  │ Lambda  │  │  │Redis │  │
                        │  │  Claude    │  │ Tool    │  │  │Elasti│  │
                        │  │  Inference │  │ Sandbox │  │  │Cache │  │
                        │  └────────────┘  └─────────┘  │  └──────┘  │
                        │                               │            │
                        │                    ┌──────────▼─────────┐  │
                        │                    │   RDS PostgreSQL   │  │
                        │                    │   (Multi-AZ)       │  │
                        │                    └────────────────────┘  │
                        │                                            │
                        │  ┌──────────┐  ┌───────────┐  ┌────────┐  │
                        │  │ S3       │  │ Cognito   │  │ Cloud  │  │
                        │  │ Sessions │  │ Auth      │  │ Watch  │  │
                        │  └──────────┘  └───────────┘  └────────┘  │
                        └──────────────────────────────────────────────┘
```

---

## 2. Network Architecture (VPC)

### 2.1 VPC Design

```
VPC: 10.0.0.0/16 (65,536 IPs)
├── Public Subnets (ALB, NAT Gateway)
│   ├── 10.0.1.0/24  (AZ-a, 254 IPs)
│   └── 10.0.2.0/24  (AZ-b, 254 IPs)
├── Private Subnets (ECS, Lambda, RDS)
│   ├── 10.0.10.0/24 (AZ-a, 254 IPs)
│   └── 10.0.11.0/24 (AZ-b, 254 IPs)
└── Isolated Subnets (RDS only, no internet)
    ├── 10.0.20.0/24 (AZ-a, 254 IPs)
    └── 10.0.21.0/24 (AZ-b, 254 IPs)
```

### 2.2 Security Groups

| Security Group | Inbound | Outbound | Attached To |
|---------------|---------|----------|-------------|
| `sg-alb` | 443 (0.0.0.0/0) | All to sg-ecs | ALB |
| `sg-ecs` | 3100 (sg-alb) | All | ECS Tasks |
| `sg-lambda` | None (invoked) | 443 (0.0.0.0/0), 5432 (sg-rds) | Lambda Functions |
| `sg-rds` | 5432 (sg-ecs, sg-lambda) | None | RDS |
| `sg-redis` | 6379 (sg-ecs) | None | ElastiCache |
| `sg-vpc-endpoint` | 443 (10.0.0.0/16) | None | VPC Endpoints |

### 2.3 VPC Endpoints (Reduce NAT costs)

| Service | Endpoint Type | Purpose |
|---------|---------------|---------|
| S3 | Gateway | Session artifacts |
| Bedrock | Interface | LLM inference |
| CloudWatch Logs | Interface | Log shipping |
| ECR | Interface | Container image pull |
| Secrets Manager | Interface | API key retrieval |

---

## 3. Compute -- ECS Fargate (API Gateway)

### 3.1 Service Configuration

```yaml
# ECS Task Definition
Task:
  Family: claude-code-api
  CPU: 1024      # 1 vCPU
  Memory: 2048   # 2 GB
  NetworkMode: awsvpc

  Containers:
    - Name: api-gateway
      Image: <ecr-repo>/claude-code-api:latest
      PortMappings:
        - ContainerPort: 3100  # HTTP/WS
          Protocol: tcp
      Environment:
        - DATABASE_URL: <from-secrets-manager>
        - REDIS_URL: <elasticache-endpoint>
        - S3_BUCKET: claude-code-sessions
        - BEDROCK_REGION: us-east-1
      Secrets:
        - ANTHROPIC_API_KEY: arn:aws:secretsmanager:...
        - JWT_SECRET: arn:aws:secretsmanager:...
      LogConfiguration:
        LogDriver: awslogs
        Options:
          awslogs-group: /ecs/claude-code-api
          awslogs-region: us-east-1
      HealthCheck:
        Command: ["CMD-SHELL", "curl -f http://localhost:3100/health"]
        Interval: 15
        Timeout: 5
        Retries: 3

Service:
  DesiredCount: 2  # minimum for HA
  AutoScaling:
    MinCapacity: 2
    MaxCapacity: 20
    TargetTracking:
      - Metric: ECSServiceAverageCPUUtilization
        Target: 70
      - Metric: ALBRequestCountPerTarget
        Target: 1000
```

### 3.2 Application Load Balancer

```yaml
ALB:
  Scheme: internet-facing
  Type: application
  Subnets: [public-a, public-b]

  Listeners:
    - Port: 443
      Protocol: HTTPS
      Certificate: arn:aws:acm:...:certificate/...
      DefaultAction: forward -> target-group

  TargetGroup:
    Port: 3100
    Protocol: HTTP
    HealthCheck:
      Path: /health
      Interval: 15s
      Timeout: 5s
    Stickiness:
      Enabled: true    # WebSocket requires sticky sessions
      Duration: 3600s
      Type: lb_cookie
```

---

## 4. LLM Inference -- Amazon Bedrock

### 4.1 Configuration

```yaml
Bedrock:
  Models:
    Primary:
      ModelId: anthropic.claude-sonnet-4-20250514-v1:0
      InferenceProfile: us.anthropic.claude-sonnet-4-20250514-v1:0
      MaxTokens: 16384
      Streaming: true

    Premium:
      ModelId: anthropic.claude-opus-4-20250115-v1:0
      InferenceProfile: us.anthropic.claude-opus-4-20250115-v1:0
      MaxTokens: 32768
      Streaming: true

    Fast:
      ModelId: anthropic.claude-3-5-haiku-20241022-v1:0
      MaxTokens: 8192
      Streaming: true

  Throughput:
    # On-demand (pay per token, no commitment)
    Type: ON_DEMAND

    # Provisioned Throughput (for 100+ users)
    # Type: PROVISIONED
    # ModelUnits: 2  # ~40 requests/min sustained
```

### 4.2 Bedrock vs Direct API

| Factor | Bedrock | Anthropic Direct |
|--------|---------|-----------------|
| Pricing | +20% markup | Base price |
| Latency | +10-30ms (VPC routing) | Direct internet |
| Data residency | Stays in AWS region | Anthropic servers |
| Compliance | SOC2, HIPAA, FedRAMP | SOC2 |
| VPC integration | Private endpoint | Internet |
| Rate limits | Per-account, adjustable | Per-key |
| Billing | Consolidated AWS bill | Separate |

**Recommendation**: Use Bedrock for enterprise deployments needing compliance/VPC. Use Anthropic Direct for cost-sensitive deployments.

---

## 5. Tool Execution -- Lambda Sandbox

### 5.1 Lambda Functions

```yaml
Functions:
  BashExecutor:
    Runtime: provided.al2023
    Handler: bootstrap
    MemorySize: 2048    # MB
    Timeout: 300        # 5 minutes max
    EphemeralStorage: 5120  # 5 GB /tmp
    VPC: true
    Layers:
      - arn:aws:lambda:us-east-1:...:layer:git-ripgrep:1
      - arn:aws:lambda:us-east-1:...:layer:nodejs20:1
      - arn:aws:lambda:us-east-1:...:layer:python312:1
    Environment:
      WORKSPACE_DIR: /tmp/workspace
      MAX_EXEC_TIME: 120

  FileOperations:
    Runtime: nodejs20.x
    Handler: index.handler
    MemorySize: 1024
    Timeout: 60
    VPC: true
    Environment:
      S3_BUCKET: claude-code-sessions

  MCPBridge:
    Runtime: nodejs20.x
    Handler: index.handler
    MemorySize: 512
    Timeout: 30
    VPC: true
    Environment:
      REDIS_URL: <elasticache-endpoint>
```

### 5.2 Lambda Security

- Runs in VPC private subnet (no internet unless via NAT)
- IAM role with minimal permissions (S3 read/write to specific prefix)
- Resource-based policies restrict invocation to ECS task role only
- CloudWatch Logs for audit trail
- Lambda SnapStart for reduced cold start (Java/Python)
- Provisioned Concurrency for latency-sensitive paths: 10 instances

### 5.3 Cold Start Mitigation

| Strategy | Cold Start | Cost |
|----------|-----------|------|
| On-demand | 1-5s | $0.20/1M invocations |
| Provisioned Concurrency (10) | <100ms | ~$35/mo |
| SnapStart (supported runtimes) | ~200ms | $0 extra |
| Keep-warm (CloudWatch Events) | ~500ms | ~$1/mo |

---

## 6. Database -- RDS PostgreSQL

### 6.1 Instance Configuration

```yaml
RDS:
  Engine: postgres
  EngineVersion: "16.2"
  InstanceClass: db.t4g.medium   # 2 vCPU, 4 GB RAM
  AllocatedStorage: 100          # GB, gp3
  StorageType: gp3
  MultiAZ: true
  BackupRetentionPeriod: 7
  PerformanceInsights: true

  # Scaling (for 100+ users)
  ReadReplica:
    Count: 1
    InstanceClass: db.t4g.medium

  Parameters:
    max_connections: 200
    shared_buffers: 1GB
    effective_cache_size: 3GB
    work_mem: 16MB
    maintenance_work_mem: 256MB
```

### 6.2 Schema Overview

See [04-supabase-backend.md](./04-supabase-backend.md) for full schema. The same PostgreSQL schema applies to RDS.

---

## 7. Session Storage -- S3

### 7.1 Bucket Structure

```
claude-code-sessions/
├── sessions/
│   └── {user_id}/
│       └── {session_id}/
│           ├── transcript.jsonl     # Conversation history
│           ├── tool-results/        # Tool execution outputs
│           │   ├── {tool_use_id}.json
│           │   └── ...
│           ├── file-snapshots/      # File state snapshots
│           │   ├── {snapshot_id}.tar.gz
│           │   └── ...
│           └── metadata.json        # Session metadata
├── memories/
│   └── {user_id}/
│       ├── memdir/                  # Auto-memory entries
│       └── manual/                  # User-saved memories
└── exports/
    └── {user_id}/
        └── {export_id}.md
```

### 7.2 S3 Configuration

```yaml
Bucket:
  Name: claude-code-sessions-${account_id}
  Versioning: Enabled
  Encryption: AES256 (SSE-S3)

  LifecycleRules:
    - Prefix: sessions/
      Transitions:
        - Days: 30
          StorageClass: INTELLIGENT_TIERING
      Expiration:
        Days: 365
    - Prefix: exports/
      Expiration:
        Days: 90

  CORSConfiguration: []  # No browser access

  PublicAccessBlock:
    BlockPublicAcls: true
    BlockPublicPolicy: true
    IgnorePublicAcls: true
    RestrictPublicBuckets: true
```

---

## 8. Cache -- ElastiCache Redis

### 8.1 Configuration

```yaml
ElastiCache:
  Engine: redis
  EngineVersion: "7.1"
  NodeType: cache.t4g.micro    # 0.5 GB
  NumCacheNodes: 1             # Single node for dev/small
  # NumCacheNodes: 2           # Cluster mode for production

  Parameters:
    maxmemory-policy: allkeys-lru
    timeout: 300

  Purpose:
    - MCP server state and discovery
    - Session cache (hot sessions)
    - Rate limiting counters
    - Feature flag cache (GrowthBook)
    - WebSocket connection registry
```

### 8.2 Cache Key Design

```
# MCP server state
mcp:servers:{user_id}:{server_name}    -> JSON (connection info)
mcp:tools:{user_id}                    -> JSON (available tools list)

# Session cache
session:{session_id}                    -> JSON (last 10 messages)
session:{session_id}:state             -> JSON (agent state)

# Rate limiting
ratelimit:{user_id}:tokens             -> INT (sliding window)
ratelimit:{user_id}:requests           -> INT (requests/min)

# Feature flags
ff:gates                               -> JSON (GrowthBook gates, TTL 60s)
```

---

## 9. Authentication -- Cognito

### 9.1 User Pool

```yaml
CognitoUserPool:
  Name: claude-code-users
  Policies:
    PasswordPolicy:
      MinimumLength: 8
      RequireUppercase: true
      RequireLowercase: true
      RequireNumbers: true
      RequireSymbols: false
  MfaConfiguration: OPTIONAL
  Schema:
    - Name: email
      Required: true
      Mutable: true
    - Name: plan
      Required: false
      Mutable: true
      AttributeDataType: String
    - Name: org_id
      Required: false
      Mutable: true
      AttributeDataType: String

  UserPoolClient:
    Name: claude-code-cli
    GenerateSecret: false
    ExplicitAuthFlows:
      - ALLOW_USER_SRP_AUTH
      - ALLOW_REFRESH_TOKEN_AUTH
    OAuth:
      AllowedOAuthFlows:
        - code
      AllowedOAuthScopes:
        - openid
        - profile
        - email
      CallbackURLs:
        - http://localhost:14232/callback  # CLI callback
      LogoutURLs:
        - http://localhost:14232/logout
```

### 9.2 Auth Flow (CLI)

```
1. CLI starts local HTTP server on port 14232
2. CLI opens browser to Cognito Hosted UI
3. User authenticates (email/password or SSO)
4. Cognito redirects to localhost:14232/callback?code=...
5. CLI exchanges code for tokens (PKCE flow)
6. CLI stores tokens in macOS Keychain / Linux Secret Service
7. Tokens auto-refresh via refresh_token
```

---

## 10. Monitoring -- CloudWatch

### 10.1 Dashboards

```yaml
Dashboards:
  Overview:
    Widgets:
      - Type: metric
        Title: "Active Sessions"
        Metrics:
          - Namespace: ClaudeCode
            MetricName: ActiveSessions
            Stat: Maximum
            Period: 60

      - Type: metric
        Title: "API Latency (P50/P95/P99)"
        Metrics:
          - Namespace: ClaudeCode
            MetricName: APILatency
            Stat: p50
          - Namespace: ClaudeCode
            MetricName: APILatency
            Stat: p95
          - Namespace: ClaudeCode
            MetricName: APILatency
            Stat: p99

      - Type: metric
        Title: "Token Usage per Hour"
        Metrics:
          - Namespace: ClaudeCode
            MetricName: InputTokens
            Stat: Sum
            Period: 3600
          - Namespace: ClaudeCode
            MetricName: OutputTokens
            Stat: Sum
            Period: 3600

      - Type: metric
        Title: "Tool Execution Duration"
        Metrics:
          - Namespace: ClaudeCode
            MetricName: ToolDuration
            Stat: p95

      - Type: metric
        Title: "Lambda Errors"
        Metrics:
          - Namespace: AWS/Lambda
            FunctionName: BashExecutor
            MetricName: Errors

      - Type: metric
        Title: "Cost Accumulation (USD)"
        Metrics:
          - Namespace: ClaudeCode
            MetricName: CumulativeCostUSD
            Stat: Maximum
```

### 10.2 Alarms

| Alarm | Condition | Action |
|-------|-----------|--------|
| High Error Rate | API 5xx > 5% for 5 min | SNS -> PagerDuty |
| High Latency | P95 > 5s for 10 min | SNS -> Slack |
| Database CPU | RDS CPU > 80% for 15 min | SNS -> Email |
| Token Budget | Daily tokens > threshold | SNS -> Email, throttle |
| Lambda Errors | Error count > 50/min | SNS -> PagerDuty |
| Disk Space | RDS free storage < 10 GB | SNS -> Email |

---

## 11. Cost Estimates

### 11.1 Per-Component Monthly Cost

| Component | 1 User | 10 Users | 100 Users | 1000 Users |
|-----------|--------|----------|-----------|------------|
| **ECS Fargate** (API) | $30 | $60 | $250 | $1,200 |
| **RDS** (db.t4g.medium, Multi-AZ) | $135 | $135 | $270 | $540 |
| **ElastiCache** (cache.t4g.micro) | $12 | $12 | $25 | $100 |
| **ALB** | $18 | $20 | $35 | $80 |
| **S3** (sessions) | $1 | $5 | $25 | $150 |
| **Lambda** (tool execution) | $2 | $15 | $80 | $500 |
| **CloudWatch** | $5 | $10 | $30 | $100 |
| **Cognito** | $0 | $0 | $0 | $55 |
| **NAT Gateway** | $35 | $35 | $70 | $140 |
| **Secrets Manager** | $1 | $1 | $2 | $5 |
| **Subtotal (Infra)** | **$239** | **$293** | **$787** | **$2,870** |
| | | | | |
| **Bedrock Tokens** * | $50-200 | $500-2,000 | $5,000-20,000 | $50,000-200,000 |
| | | | | |
| **Total (Low Usage)** | **$289** | **$793** | **$5,787** | **$52,870** |
| **Total (High Usage)** | **$439** | **$2,293** | **$20,787** | **$202,870** |

\* Token costs dominate. See [05-cost-analysis.md](./05-cost-analysis.md) for detailed per-developer token estimates.

### 11.2 Cost Optimization Strategies

| Strategy | Savings | Complexity |
|----------|---------|------------|
| Use Anthropic Direct instead of Bedrock | 17% on tokens | Low |
| Savings Plans (ECS, 1-year) | 30% on compute | Low |
| Reserved Instances (RDS, 1-year) | 40% on database | Low |
| Spot Fargate (non-critical tasks) | 50-70% on compute | Medium |
| Prompt caching (Anthropic) | 30-50% on input tokens | Medium |
| Local model for simple tasks (hybrid) | 60-80% on tokens | High |
| S3 Intelligent-Tiering | 20-40% on storage | Low |

### 11.3 ECS Fargate Sizing Guide

| Users | Tasks | vCPU | Memory | Est. Cost |
|-------|-------|------|--------|-----------|
| 1-10 | 2 | 0.5 each | 1 GB each | $30-60/mo |
| 10-50 | 4 | 1 each | 2 GB each | $120-240/mo |
| 50-200 | 8 | 1 each | 2 GB each | $250-500/mo |
| 200-1000 | 20 | 2 each | 4 GB each | $1,200-2,400/mo |

---

## 12. Deployment Procedure

### 12.1 Initial Setup

```bash
# 1. Deploy infrastructure
cd terraform/
terraform init
terraform apply

# 2. Build and push container image
aws ecr get-login-password | docker login --username AWS --password-stdin <account>.dkr.ecr.<region>.amazonaws.com
docker build -t claude-code-api -f Dockerfile.api .
docker tag claude-code-api:latest <account>.dkr.ecr.<region>.amazonaws.com/claude-code-api:latest
docker push <account>.dkr.ecr.<region>.amazonaws.com/claude-code-api:latest

# 3. Run database migrations
aws ecs run-task --cluster claude-code --task-definition claude-code-migrate --network-configuration ...

# 4. Store secrets
aws secretsmanager create-secret --name claude-code/anthropic-api-key --secret-string "sk-ant-..."
aws secretsmanager create-secret --name claude-code/jwt-secret --secret-string "$(openssl rand -base64 32)"

# 5. Verify
curl https://api.your-domain.com/health
```

### 12.2 CI/CD (GitHub Actions)

```yaml
name: Deploy
on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam:::<account>:role/github-deploy
          aws-region: us-east-1
      - uses: aws-actions/amazon-ecr-login@v2
      - run: |
          docker build -t $ECR_REPO:$GITHUB_SHA -f Dockerfile.api .
          docker push $ECR_REPO:$GITHUB_SHA
          aws ecs update-service --cluster claude-code --service api-gateway \
            --force-new-deployment
```
