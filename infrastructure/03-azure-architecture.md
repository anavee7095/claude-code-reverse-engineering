# 03 -- Azure Architecture

## Overview

Full production deployment on Microsoft Azure, leveraging Azure OpenAI Service for LLM inference, Azure Container Apps for the API gateway, and Azure Functions for tool sandboxing. Ideal for organizations already invested in the Microsoft ecosystem or requiring Azure-specific compliance certifications.

---

## 1. Architecture Diagram

```
                        ┌──────────────────────────────────────────────┐
                        │               Azure Cloud                    │
                        │                                              │
  CLI Client ──────────>│  ┌──────────────┐     ┌──────────────────┐  │
  (WebSocket/SSE)       │  │ Azure Front  │────>│ Container Apps   │  │
                        │  │ Door / AGW   │     │ Environment      │  │
                        │  └──────────────┘     │ ┌──────────────┐ │  │
                        │                       │ │ api-gw (x3)  │ │  │
                        │                       │ └──────┬───────┘ │  │
                        │                       └────────┼─────────┘  │
                        │                                │            │
                        │        ┌───────────────────────┼──────┐     │
                        │        │                       │      │     │
                        │  ┌─────▼──────┐  ┌─────────┐  │  ┌───▼──┐  │
                        │  │ Azure      │  │ Azure   │  │  │Azure │  │
                        │  │ OpenAI     │  │Functions│  │  │Cache │  │
                        │  │ Service    │  │ (Tool   │  │  │Redis │  │
                        │  │            │  │ Sandbox)│  │  │      │  │
                        │  └────────────┘  └─────────┘  │  └──────┘  │
                        │                               │            │
                        │                    ┌──────────▼─────────┐  │
                        │                    │   Azure Database   │  │
                        │                    │   for PostgreSQL   │  │
                        │                    │   (Flexible)       │  │
                        │                    └────────────────────┘  │
                        │                                            │
                        │  ┌──────────┐  ┌───────────┐  ┌────────┐  │
                        │  │ Blob     │  │ Azure AD  │  │ Azure  │  │
                        │  │ Storage  │  │ B2C       │  │Monitor │  │
                        │  └──────────┘  └───────────┘  └────────┘  │
                        └──────────────────────────────────────────────┘
```

---

## 2. Network Architecture (VNet)

### 2.1 VNet Design

```
VNet: 10.1.0.0/16 (65,536 IPs)
├── Public Subnet (Application Gateway)
│   └── 10.1.1.0/24  (254 IPs)
├── Container Apps Subnet (delegated)
│   └── 10.1.10.0/23 (510 IPs, required /23 minimum for Container Apps)
├── Functions Subnet (delegated, VNet integration)
│   └── 10.1.12.0/24 (254 IPs)
├── Database Subnet (delegated)
│   └── 10.1.20.0/24 (254 IPs)
└── Cache Subnet
    └── 10.1.21.0/24 (254 IPs)
```

### 2.2 Network Security Groups (NSG)

| NSG | Inbound Rules | Outbound Rules | Attached To |
|-----|--------------|----------------|-------------|
| `nsg-appgw` | 443 (Internet), 65200-65535 (GatewayManager) | All to nsg-aca | App Gateway subnet |
| `nsg-aca` | 3100 (nsg-appgw) | 443 (Internet), 5432 (nsg-db), 6380 (nsg-cache) | Container Apps subnet |
| `nsg-functions` | None (triggered) | 443 (Internet), 5432 (nsg-db) | Functions subnet |
| `nsg-db` | 5432 (nsg-aca, nsg-functions) | None | Database subnet |
| `nsg-cache` | 6380 (nsg-aca) | None | Cache subnet |

### 2.3 Private Endpoints

| Service | Private Endpoint | DNS Zone |
|---------|-----------------|----------|
| Azure OpenAI | PE for inference | privatelink.openai.azure.com |
| Blob Storage | PE for sessions | privatelink.blob.core.windows.net |
| Key Vault | PE for secrets | privatelink.vaultcore.azure.net |

---

## 3. LLM Inference -- Azure OpenAI Service

### 3.1 Deployment Configuration

```json
{
  "deployments": [
    {
      "name": "claude-sonnet-4",
      "model": {
        "name": "claude-sonnet-4-20250514",
        "version": "2025-05-14",
        "format": "Anthropic"
      },
      "sku": {
        "name": "GlobalStandard",
        "capacity": 80
      },
      "note": "Azure OpenAI supports Anthropic models via cross-provider agreement"
    },
    {
      "name": "gpt-4o-main",
      "model": {
        "name": "gpt-4o",
        "version": "2024-11-20",
        "format": "OpenAI"
      },
      "sku": {
        "name": "GlobalStandard",
        "capacity": 150
      }
    },
    {
      "name": "gpt-4.1-reasoning",
      "model": {
        "name": "gpt-4.1",
        "version": "2025-04-14",
        "format": "OpenAI"
      },
      "sku": {
        "name": "GlobalStandard",
        "capacity": 80
      }
    },
    {
      "name": "gpt-4o-mini-fast",
      "model": {
        "name": "gpt-4o-mini",
        "version": "2024-07-18",
        "format": "OpenAI"
      },
      "sku": {
        "name": "GlobalStandard",
        "capacity": 300
      }
    }
  ]
}
```

### 3.2 Azure OpenAI Pricing (Pay-As-You-Go)

| Model | Input $/M | Output $/M | Context | Tool Use |
|-------|-----------|------------|---------|----------|
| GPT-4o | $2.50 | $10.00 | 128K | Full |
| GPT-4.1 | $2.00 | $8.00 | 1M | Full |
| GPT-4o-mini | $0.15 | $0.60 | 128K | Full |
| Claude Sonnet 4 (via Azure) | $3.00 | $15.00 | 200K | Full |
| Claude Opus 4 (via Azure) | $15.00 | $75.00 | 200K | Full |

### 3.3 Provisioned Throughput Units (PTU) for Scale

For predictable workloads (100+ users), PTUs provide guaranteed throughput:

| Model | PTU Price/hr | ~Tokens/min/PTU | Monthly (1 PTU) |
|-------|-------------|-----------------|-----------------|
| GPT-4o | $1.55 | ~10K output | $1,116 |
| GPT-4o-mini | $0.22 | ~75K output | $158 |

**Break-even**: PTUs become cheaper than pay-as-you-go at ~60% sustained utilization.

---

## 4. Compute -- Azure Container Apps

### 4.1 Container App Configuration

```yaml
# container-app.yaml
properties:
  managedEnvironmentId: /subscriptions/.../managedEnvironments/claude-code-env
  configuration:
    activeRevisionsMode: Multiple
    ingress:
      external: true
      targetPort: 3100
      transport: http
      allowInsecure: false
      traffic:
        - latestRevision: true
          weight: 100
      stickySessions:
        affinity: sticky  # Required for WebSocket
    secrets:
      - name: anthropic-api-key
        keyVaultUrl: https://claude-code-kv.vault.azure.net/secrets/anthropic-api-key
        identity: system
      - name: db-connection-string
        keyVaultUrl: https://claude-code-kv.vault.azure.net/secrets/db-connection-string
        identity: system
    registries:
      - server: claudecodeacr.azurecr.io
        identity: system

  template:
    containers:
      - name: api-gateway
        image: claudecodeacr.azurecr.io/api-gateway:latest
        resources:
          cpu: 1.0
          memory: 2Gi
        env:
          - name: DATABASE_URL
            secretRef: db-connection-string
          - name: ANTHROPIC_API_KEY
            secretRef: anthropic-api-key
          - name: REDIS_URL
            value: "rediss://claude-code-cache.redis.cache.windows.net:6380"
          - name: AZURE_OPENAI_ENDPOINT
            value: "https://claude-code-aoai.openai.azure.com"
        probes:
          - type: liveness
            httpGet:
              path: /health
              port: 3100
            periodSeconds: 10
          - type: readiness
            httpGet:
              path: /health
              port: 3100
            initialDelaySeconds: 5

    scale:
      minReplicas: 2
      maxReplicas: 20
      rules:
        - name: http-scaling
          http:
            metadata:
              concurrentRequests: "50"
        - name: cpu-scaling
          custom:
            type: cpu
            metadata:
              type: Utilization
              value: "70"
```

### 4.2 Container Apps Environment

```yaml
Environment:
  Name: claude-code-env
  Location: eastus
  Workload Profile:
    - Name: general
      WorkloadProfileType: D4      # 4 vCPU, 16 GB
      MinimumCount: 2
      MaximumCount: 10

  VNet Integration:
    SubnetId: /subscriptions/.../subnets/aca-subnet
    Internal: false

  Logging:
    Destination: azure-monitor
    LogAnalyticsWorkspaceId: /subscriptions/.../workspaces/claude-code-logs
```

---

## 5. Tool Execution -- Azure Functions

### 5.1 Function App Configuration

```yaml
FunctionApp:
  Name: claude-code-tools
  Runtime: node
  RuntimeVersion: 20
  OS: linux
  Plan: Premium (EP1)    # VNet integration required
  VNetIntegration: true

  Functions:
    BashExecutor:
      Trigger: HTTP
      AuthLevel: function
      Timeout: 300    # 5 minutes
      Memory: 1536    # MB

    FileOperations:
      Trigger: HTTP
      AuthLevel: function
      Timeout: 60
      Memory: 1024

    MCPBridge:
      Trigger: HTTP
      AuthLevel: function
      Timeout: 30
      Memory: 512

  AppSettings:
    FUNCTIONS_WORKER_RUNTIME: node
    WEBSITE_NODE_DEFAULT_VERSION: ~20
    AzureWebJobsStorage: <storage-connection-string>
    WORKSPACE_BASE: /tmp/workspaces
    MAX_EXEC_TIME: 120
```

### 5.2 Azure Functions Pricing

| Plan | Price | VNet | Scale | Best For |
|------|-------|------|-------|----------|
| Consumption | $0.20/M executions + $0.000016/GB-s | No | 0-200 | Dev/test |
| Premium (EP1) | ~$145/mo | Yes | 1-20 | Production |
| Premium (EP2) | ~$290/mo | Yes | 1-20 | High throughput |

---

## 6. Database -- Azure Database for PostgreSQL

### 6.1 Configuration

```yaml
PostgreSQL:
  Sku: GP_Standard_D2ds_v5     # 2 vCPU, 8 GB RAM
  StorageSizeGB: 128
  Version: "16"
  HighAvailability:
    Mode: ZoneRedundant          # Production
    # Mode: Disabled             # Dev/test
  Backup:
    RetentionDays: 7
    GeoRedundantBackup: Disabled

  # For 100+ users
  ReadReplica:
    Count: 1
    Sku: GP_Standard_D2ds_v5

  ServerParameters:
    max_connections: 200
    shared_buffers: 2GB
    effective_cache_size: 6GB
```

### 6.2 Pricing

| SKU | vCPU | RAM | Storage | Monthly |
|-----|------|-----|---------|---------|
| B_Standard_B1ms | 1 | 2 GB | 32 GB | $25 |
| GP_Standard_D2ds_v5 | 2 | 8 GB | 128 GB | $190 |
| GP_Standard_D4ds_v5 | 4 | 16 GB | 256 GB | $380 |
| MO_Standard_E2ds_v5 | 2 | 16 GB | 256 GB | $260 |

---

## 7. Storage -- Azure Blob Storage

### 7.1 Configuration

```yaml
StorageAccount:
  Name: claudecodesessions
  Kind: StorageV2
  Sku: Standard_LRS     # Locally redundant (cheapest)
  # Sku: Standard_GRS   # Geo-redundant (production)
  AccessTier: Hot

  Containers:
    - Name: sessions
      PublicAccess: None
    - Name: memories
      PublicAccess: None
    - Name: exports
      PublicAccess: None

  LifecycleManagement:
    Rules:
      - Name: archive-old-sessions
        Filters:
          BlobTypes: [blockBlob]
          PrefixMatch: [sessions/]
        Actions:
          BaseBlob:
            TierToCool:
              DaysAfterModificationGreaterThan: 30
            TierToArchive:
              DaysAfterModificationGreaterThan: 90
            Delete:
              DaysAfterModificationGreaterThan: 365
```

---

## 8. Cache -- Azure Cache for Redis

### 8.1 Configuration

```yaml
RedisCache:
  Name: claude-code-cache
  Sku: Basic_C1          # 1 GB (dev/small)
  # Sku: Standard_C1     # 1 GB with replication (production)
  # Sku: Premium_P1      # 6 GB, VNet support (enterprise)
  Version: "7.2"
  TLSVersion: "1.2"
  EnableNonSslPort: false

  AccessPolicy:
    - PrincipalId: <container-app-managed-identity>
      AccessPolicyName: Data Owner
```

### 8.2 Pricing

| SKU | Size | Replication | VNet | Monthly |
|-----|------|-------------|------|---------|
| Basic C0 | 250 MB | No | No | $16 |
| Basic C1 | 1 GB | No | No | $40 |
| Standard C1 | 1 GB | Yes | No | $80 |
| Premium P1 | 6 GB | Yes | Yes | $300 |

---

## 9. Authentication -- Azure AD B2C

### 9.1 Tenant Configuration

```yaml
AzureADB2C:
  TenantName: claudecodeauth
  Policies:
    SignUpSignIn:
      Type: B2C_1_signup_signin
      IdentityProviders:
        - Local (Email)
        - GitHub
        - Microsoft
      UserAttributes:
        - DisplayName
        - Email
      Claims:
        - email
        - name
        - sub
        - plan
        - org_id

    PasswordReset:
      Type: B2C_1_password_reset

  Applications:
    - Name: claude-code-cli
      RedirectURIs:
        - http://localhost:14232/callback
      ImplicitGrant: false
      PublicClient: true     # CLI app, no client secret
```

### 9.2 Pricing

| Tier | Authentications/month | Price |
|------|----------------------|-------|
| Free | 50,000 | $0 |
| Premium P1 | Unlimited | $0.003/auth |
| Premium P2 | Unlimited + ID Protection | $0.009/auth |

---

## 10. Monitoring -- Azure Monitor

### 10.1 Application Insights

```yaml
ApplicationInsights:
  Name: claude-code-insights
  WorkspaceId: <log-analytics-workspace-id>

  Features:
    - Live Metrics
    - Availability Tests
    - Distributed Tracing
    - Smart Detection

  CustomMetrics:
    - Name: ActiveSessions
    - Name: TokenUsage.Input
    - Name: TokenUsage.Output
    - Name: ToolExecution.Duration
    - Name: CostUSD.Cumulative
```

### 10.2 Alerts

| Alert | Condition | Action |
|-------|-----------|--------|
| High Error Rate | Exceptions > 50 in 5 min | Email + Teams |
| Slow Response | Server response > 5s P95 | Email |
| Database DTU | DTU > 80% for 15 min | Email + Scale |
| Budget Alert | Daily cost > $X | Email + Throttle |

### 10.3 Log Analytics Queries (KQL)

```kql
// Top errors in last 24h
exceptions
| where timestamp > ago(24h)
| summarize count() by outerMessage
| top 10 by count_

// Token usage per user
customMetrics
| where name == "TokenUsage.Output"
| where timestamp > ago(24h)
| summarize TotalTokens = sum(value) by tostring(customDimensions.userId)
| top 20 by TotalTokens

// Average tool execution time
customMetrics
| where name == "ToolExecution.Duration"
| where timestamp > ago(1h)
| summarize avg(value), percentile(value, 95) by tostring(customDimensions.toolName)
```

---

## 11. Cost Estimates

### 11.1 Per-Component Monthly Cost

| Component | 1 User | 10 Users | 100 Users | 1000 Users |
|-----------|--------|----------|-----------|------------|
| **Container Apps** (D4 workload) | $35 | $70 | $280 | $1,400 |
| **PostgreSQL** (GP D2ds) | $190 | $190 | $380 | $760 |
| **Redis** (Basic C1) | $40 | $40 | $80 | $300 |
| **Azure Front Door** | $35 | $38 | $55 | $120 |
| **Blob Storage** | $1 | $5 | $25 | $150 |
| **Functions** (Premium EP1) | $145 | $145 | $290 | $580 |
| **Application Insights** | $3 | $10 | $40 | $150 |
| **Azure AD B2C** | $0 | $0 | $0 | $30 |
| **Key Vault** | $1 | $1 | $2 | $5 |
| **VNet/Networking** | $10 | $10 | $20 | $50 |
| **Subtotal (Infra)** | **$460** | **$509** | **$1,172** | **$3,545** |
| | | | | |
| **Azure OpenAI Tokens** * | $40-150 | $400-1,500 | $4,000-15,000 | $40,000-150,000 |
| | | | | |
| **Total (Low)** | **$500** | **$909** | **$5,172** | **$43,545** |
| **Total (High)** | **$610** | **$2,009** | **$16,172** | **$153,545** |

\* Token costs depend on usage. See [05-cost-analysis.md](./05-cost-analysis.md) for breakdown.

### 11.2 Azure vs AWS Comparison

| Component | AWS | Azure | Difference |
|-----------|-----|-------|------------|
| Compute (API) | $30-60 | $35-70 | Azure ~15% more |
| Database | $135 | $190 | Azure ~40% more |
| Cache | $12 | $40 | Azure ~230% more |
| Functions | $2-35 | $145 | Azure much more (Premium plan) |
| Load Balancer | $18 | $35 | Azure ~90% more |
| **Infra Total** | **$239** | **$460** | **Azure ~90% more** |
| LLM Tokens | Same | Same | Equivalent |

**Note**: Azure infrastructure costs are higher than AWS primarily due to the Azure Functions Premium plan requirement for VNet integration and the higher base price of Azure Cache for Redis. However, Azure may be preferred when:
- Organization already has Azure Enterprise Agreement (discounts up to 40%)
- Azure-specific compliance requirements (Azure Government, etc.)
- Existing Azure AD integration needed
- Microsoft 365 / Teams integration desired

---

## 12. Deployment with Azure CLI

```bash
# 1. Create resource group
az group create --name claude-code-rg --location eastus

# 2. Deploy infrastructure (ARM/Bicep)
az deployment group create \
  --resource-group claude-code-rg \
  --template-file azure-infra.bicep \
  --parameters @azure-params.json

# 3. Build and push container
az acr build \
  --registry claudecodeacr \
  --image api-gateway:latest \
  --file Dockerfile.api .

# 4. Deploy Container App
az containerapp update \
  --name claude-code-api \
  --resource-group claude-code-rg \
  --image claudecodeacr.azurecr.io/api-gateway:latest

# 5. Store secrets
az keyvault secret set \
  --vault-name claude-code-kv \
  --name anthropic-api-key \
  --value "sk-ant-..."

# 6. Verify
curl https://claude-code-api.azurecontainerapps.io/health
```
