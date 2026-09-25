# ACE Monorepo — Architecture Diagrams

**Repo:** `AgentCert/ace-monorepo` · **Platform:** Agent Certification Engine (ACE)

---

## 1. `main` Branch — Full Architecture

```mermaid
%%{init: {'theme': 'base', 'themeVariables': {'fontSize': '20px', 'fontFamily': 'monospace'}}}%%
flowchart TD
    subgraph CONTROL["🖥️ Control Plane (AgentCert submodule — Go/GraphQL)"]
        AUTH["Auth Service\nREST :3000 · gRPC :3030"]
        GQL["GraphQL API\nGo/gqlgen :8081 · gRPC :8082"]
        WEB["React UI\nnginx :2001 · TypeScript"]
        MONGO["MongoDB :27017\nReplica Set rs0"]
        AUTH --> MONGO
        GQL --> MONGO
        WEB --> GQL
    end

    subgraph K8S["☸️ Kubernetes Cluster (kind / AKS / EKS / GKE)"]
        subgraph APPS["Target Apps (app-charts — Helm)"]
            SOCKSHOP["Sock Shop\n(microservices)"]
            OTEL["OTel Demo\n(otel-demo ns)"]
            BOOKINFO["Bookinfo\n(Istio · book-info ns)"]
        end

        subgraph MCP["MCP Servers (app-charts)"]
            KMCP["kubernetes-mcp-server\n(K8s API access)"]
            PMCP["prometheus-mcp-server\n(metrics access)"]
        end

        subgraph FAULTS["Fault Catalog (chaos-charts:main)"]
            GENERIC["faults/kubernetes/\n35 generic K8s faults\npod-delete · cpu-hog · disk-fill\ncontainer-kill · network-chaos …"]
            LITMUSGO["litmus-go\n(Go fault executors)"]
            GENERIC --> LITMUSGO
        end

        subgraph AGENTPOD["SRE Agent Pod (agent-charts — Helm)"]
            FLASH["flash-agent\nPython · FLASH methodology\nDISCOVER → REASON+ACT\n→ ANALYZE → REFLECT\nOpenAI SDK + MCP tools"]
            SIDECAR["agent-sidecar\nstamps experiment_id\nagent_id · trace_id\ninto LLM requests"]
        end
    end

    subgraph GATEWAY["🔀 LLM Gateway (agentcert-stack — LiteLLM :14000)"]
        AZURE["Azure GPT-4o\n/ o-series"]
        GEMINI["Gemini 2.5 Pro"]
        OPENROUTER["OpenRouter"]
    end

    subgraph OBS["📊 Observability (Langfuse :4000)"]
        LANGFUSE["Langfuse\nPostgres + ClickHouse + MinIO\n(raw LLM traces)"]
    end

    subgraph CERT["📋 Certification Pipeline (certifier:main — FastAPI :8000)"]
        P0["Phase 0\nFault bucketing\n(ingest Langfuse traces)"]
        P1["Phase 1\nMetrics extraction\nper fault"]
        P2["Phase 2\nStatistical aggregation"]
        P3["Phase 3\nBuild 12-section\nJSON + PDF report"]
        P0 --> P1 --> P2 --> P3
    end

    GQL -->|"drives experiments\nregisters infra"| K8S
    LITMUSGO -->|"injects faults into"| APPS
    FLASH -->|"observes via MCP"| KMCP
    FLASH -->|"observes via MCP"| PMCP
    SIDECAR -->|"forwards stamped\nLLM calls"| GATEWAY
    FLASH --> SIDECAR
    GATEWAY -->|"Langfuse callback\nOTEL traces"| LANGFUSE
    LANGFUSE -->|"raw traces"| P0
    P3 -->|"certification_metadata\nscorecard"| GQL
```

---

## 2. `feature/itbench-scenarios` Branch — Full Architecture

```mermaid
%%{init: {'theme': 'base', 'themeVariables': {'fontSize': '20px', 'fontFamily': 'monospace'}}}%%
flowchart TD
    subgraph CONTROL["🖥️ Control Plane (unchanged from main)"]
        AUTH["Auth Service\nREST :3000 · gRPC :3030"]
        GQL["GraphQL API\nGo/gqlgen :8081 · gRPC :8082"]
        WEB["React UI\nnginx :2001 · TypeScript"]
        MONGO["MongoDB :27017\nReplica Set rs0"]
        AUTH --> MONGO
        GQL --> MONGO
        WEB --> GQL
    end

    subgraph K8S["☸️ Kubernetes Cluster"]
        subgraph APPS["Target Apps (app-charts — adds ITBench Argo Workflow)"]
            SOCKSHOP["Sock Shop"]
            OTEL["OTel Demo"]
            BOOKINFO["Bookinfo (Istio)"]
            ITELLDEMO["otel-demo-itbench\n⬆ NEW — ITBench Argo Workflow"]
        end

        subgraph MCP["MCP Servers (unchanged)"]
            KMCP["kubernetes-mcp-server"]
            PMCP["prometheus-mcp-server"]
        end

        subgraph FAULTS["Fault Catalog (chaos-charts:feature/itbench-scenarios)"]
            GENERIC["faults/kubernetes/\n35 generic K8s faults"]
            ITBENCH_FAULTS["faults/itbench/ ⬆ NEW\n30 ITBench SRE fault bundles\nmisconfigured workloads · deleted services\nresource quota exceeded · HPA misconfig\nnode failure · image pull errors\nOOM kills · DNS failures · …"]
            LITMUSGO["litmus-go\n(Go fault executors)"]
            GENERIC --> LITMUSGO
            ITBENCH_FAULTS --> LITMUSGO
        end

        subgraph SREAGENTPOD["SRE Agent Pod (agent-charts — Helm)"]
            FLASH["flash-agent\nFLASH methodology\n(unchanged)"]
            SIDECAR["agent-sidecar\n(unchanged)"]
            FLASH --> SIDECAR
        end

        subgraph CISOAGENTPOD["CISO Agent Pod ⬆ NEW (agents/)"]
            CISOAGENT["ciso-agent\nCrewAI + LangGraph\ngenerates Kyverno / OPA\ncompliance policies"]
            SREAGENT["sre-agent (ITBench ref.)\nCodex CLI + Zero runner\n(upstream unmodified)"]
        end
    end

    subgraph GATEWAY["🔀 LLM Gateway (agentcert-stack — LiteLLM :14000)"]
        AZURE["Azure GPT-4o"]
        GEMINI["Gemini 2.5 Pro"]
        OPENROUTER["OpenRouter"]
        OLLAMA["Ollama\nqwen2.5-7b-instruct ⬆ NEW\n(open-weight / local)"]
    end

    subgraph OBS["📊 Observability (Langfuse :4000 — unchanged)"]
        LANGFUSE["Langfuse\nPostgres + ClickHouse + MinIO"]
    end

    subgraph CERT["📋 Certification Pipeline (certifier:feature/itbench-scenarios)"]
        P0["Phase 0\nFault bucketing"]
        P1["Phase 1\nMetrics extraction"]
        P2["Phase 2\nStatistical aggregation"]
        P3["Phase 3\nJSON + PDF report"]

        subgraph CISO_PATH["CISO Scorecard Path ⬆ NEW"]
            CA["ciso_metrics_adapter.py"]
            CC["compute_ciso_*.py\naggregators"]
            CF["--include-ciso-finops\nflag"]
            CA --> CC --> CF
        end

        P0 --> P1 --> P2 --> P3
        P1 --> CA
    end

    GQL -->|"drives experiments"| K8S
    LITMUSGO -->|"injects faults"| APPS
    FLASH -->|"MCP tools"| KMCP
    FLASH -->|"MCP tools"| PMCP
    CISOAGENT -->|"MCP tools"| KMCP
    SIDECAR -->|"stamped LLM calls"| GATEWAY
    CISOAGENT -->|"LLM calls\n(openai_compatible)"| GATEWAY
    GATEWAY -->|"Langfuse callback"| LANGFUSE
    LANGFUSE -->|"raw traces"| P0
    CF -->|"CISO scorecard"| GQL
    P3 -->|"SRE certification"| GQL
```

---

## 3. Delta — What Changed Between Branches

```mermaid
%%{init: {'theme': 'base', 'themeVariables': {'fontSize': '20px', 'fontFamily': 'monospace'}}}%%
flowchart LR
    subgraph UNCHANGED["✅ Unchanged (same submodule pointer on both branches)"]
        direction TB
        U1["AgentCert\n(control plane)"]
        U2["agent-sidecar"]
        U3["flash-agent"]
        U4["agent-charts"]
        U5["litmus-go"]
    end

    subgraph MODIFIED["🔄 Modified Submodules (branch pointer changed)"]
        direction TB

        subgraph CC["chaos-charts"]
            CC_MAIN["main:\nAgentCert/chaos-charts:main\n35 generic K8s faults"]
            CC_ITB["itbench-scenarios:\nAgentCert/chaos-charts:feature/itbench-scenarios\n35 generic + 30 ITBench SRE fault bundles"]
            CC_MAIN -->|"+ faults/itbench/"| CC_ITB
        end

        subgraph CF["certifier"]
            CF_MAIN["main:\nAgentCert/certifier:main\nSRE scorecard only\nCloud LLM providers only"]
            CF_ITB["itbench-scenarios:\nAgentCert/certifier:feature/itbench-scenarios\n+ CISO scorecard path\n+ FinOps scoring\n+ openai_compatible provider"]
            CF_MAIN -->|"+ ciso_metrics_adapter.py\n+ compute_ciso_*.py\n+ openai_compatible"| CF_ITB
        end

        subgraph AS["agentcert-stack (LiteLLM config)"]
            AS_MAIN["main:\nAzure · Gemini · OpenRouter"]
            AS_ITB["itbench-scenarios:\nAzure · Gemini · OpenRouter\n+ Ollama qwen2.5-7b-instruct"]
            AS_MAIN -->|"+ Ollama entry\n+ openai_compatible path"| AS_ITB
        end

        subgraph AC["app-charts"]
            AC_MAIN["main:\nsock-shop · otel-demo · bookinfo\nMCP servers"]
            AC_ITB["itbench-scenarios:\nsame + otel-demo-itbench\nArgo Workflow"]
            AC_MAIN -->|"+ otel-demo-itbench\nArgo Workflow"| AC_ITB
        end
    end

    subgraph NEW["🆕 New Submodules (not in main)"]
        direction TB
        NA["agents/ciso-agent\ninlined from itbench-hub/ITBench-CISO-CAA-Agent\nCrewAI + LangGraph\ngenerates Kyverno/OPA policies\nOpenAI-compatible (works with Ollama)"]
        NB["agents/sre-agent\nitbench-hub/ITBench-CISO-SRE-FinOps-Agent\nCodex CLI + Zero runner\nITBench upstream reference agent"]
        NC["agents/flash-agent (inline snapshot)\nplain-code copy of root flash-agent/\nfor portability"]
    end
```

---

## 4. Submodule Map — Both Branches Side-by-Side

```mermaid
%%{init: {'theme': 'base', 'themeVariables': {'fontSize': '20px', 'fontFamily': 'monospace'}}}%%
flowchart TD
    subgraph MONO["ace-monorepo"]
        subgraph MAIN_COL["main branch"]
            M1["AgentCert → AgentCert/AgentCert:main"]
            M2["certifier → AgentCert/certifier:main"]
            M3["flash-agent → AgentCert/flash-agent:main"]
            M4["agent-sidecar → AgentCert/agent-sidecar:main"]
            M5["chaos-charts → AgentCert/chaos-charts:main"]
            M6["app-charts → AgentCert/app-charts:main"]
            M7["agent-charts → AgentCert/agent-charts:main"]
            M8["agentcert-stack → AgentCert/agentcert-stack:main"]
            M9["litmus-go → AgentCert/litmus-go:master"]
        end

        subgraph ITB_COL["feature/itbench-scenarios branch"]
            I1["AgentCert → AgentCert/AgentCert:main ✅"]
            I2["certifier → AgentCert/certifier:feature/itbench-scenarios 🔄"]
            I3["flash-agent → AgentCert/flash-agent:main ✅"]
            I4["agent-sidecar → AgentCert/agent-sidecar:main ✅"]
            I5["chaos-charts → AgentCert/chaos-charts:feature/itbench-scenarios 🔄"]
            I6["app-charts → AgentCert/app-charts:main 🔄"]
            I7["agent-charts → AgentCert/agent-charts:main ✅"]
            I8["agentcert-stack → AgentCert/agentcert-stack:main 🔄"]
            I9["litmus-go → AgentCert/litmus-go:master ✅"]
            I10["agents/ciso-agent → inlined from itbench-hub/ITBench-CISO-CAA-Agent 🆕"]
            I11["agents/sre-agent → itbench-hub/ITBench-CISO-SRE-FinOps-Agent 🆕"]
        end
    end

    M1 -.->|"same"| I1
    M2 -.->|"branch changed"| I2
    M3 -.->|"same"| I3
    M4 -.->|"same"| I4
    M5 -.->|"branch changed"| I5
    M6 -.->|"branch changed"| I6
    M7 -.->|"same"| I7
    M8 -.->|"branch changed"| I8
    M9 -.->|"same"| I9
```

---

## Legend

| Symbol | Meaning |
|--------|---------|
| ✅ | Unchanged between branches |
| 🔄 | Submodule pointer changed (different branch) |
| 🆕 | New — exists only on `feature/itbench-scenarios` |
| ⬆ NEW | Component added on `feature/itbench-scenarios` |
