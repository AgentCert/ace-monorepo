# ACE Monorepo

AgentCert monorepo containing all project components as git submodules.

## Submodules

| Module | Description |
|--------|-------------|
| [AgentCert](./AgentCert) | Core AgentCert platform |
| [app-charts](./app-charts) | Application Helm charts |
| [agent-charts](./agent-charts) | Agent Helm charts |
| [certifier](./certifier) | Certification engine |
| [flash-agent](./flash-agent) | Flash agent implementation |
| [agentcert-stack](./agentcert-stack) | Full stack deployment |
| [chaos-charts](./chaos-charts) | Chaos engineering charts |

## Getting Started

### Clone with submodules

```bash
git clone --recurse-submodules <repo-url>
```

### Initialize submodules (if already cloned)

```bash
git submodule update --init --recursive
```

### Update all submodules to latest

```bash
git submodule update --remote --merge
```

## License

[MIT](./LICENSE)
