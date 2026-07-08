# Model Library — Storage Architecture Reference

From spec §26.4.

---

## Storage Layout

Each Model Library entry maps to three resources:

| Resource | Location | What it contains |
|---|---|---|
| MongoDB document | `model_library_collection` | alias, provider, model, baseURL, litellmDeployId, secretRef |
| K8s Secret | `litmus` namespace, name: `ace-model-<alias>-<projectID>` | API key as `API_KEY` data field |
| LiteLLM model entry | LiteLLM internal DB, registered via `/config/add_model` | Model routing configuration |

---

## K8s Secret Naming

```
ace-model-<alias>-<projectID>
```

**Sanitisation rule:** Replace non-alphanumeric characters with `-`, lowercase, truncate to 63 chars.

```go
func modelSecretName(alias, projectID string) string {
    s := strings.ToLower(alias + "-" + projectID)
    re := regexp.MustCompile(`[^a-z0-9-]`)
    s = re.ReplaceAllString(s, "-")
    if len(s) > 63 {
        s = s[:63]
    }
    return "ace-model-" + s
}
```

---

## LiteLLM API Payload

`POST <LITELLM_ADMIN_URL>/config/add_model`

```json
{
  "model_name": "my-openai-gpt4o",
  "litellm_params": {
    "model": "openai/gpt-4o",
    "api_key": "os.environ/ACE_MODEL_MY_OPENAI_GPT4O",
    "api_base": "https://api.openai.com/v1"
  }
}
```

**`api_key` env var convention:** `ACE_MODEL_<ALIAS_UPPER_SNAKE>` where alias is uppercased with `-` → `_`.

Example: alias `my-openai-gpt4o` → env var `ACE_MODEL_MY_OPENAI_GPT4O`.

LiteLLM must be configured with this env var pointing to the K8s Secret's API_KEY value. The LiteLLM pod mounts secrets from `litmus` namespace — this mounting is handled by the `litellm` Helm chart.

---

## Difference: Model Library Secret vs Experiment Secret

| | Model Library Secret | Experiment Secret |
|---|---|---|
| Name pattern | `ace-model-<alias>-<projectID>` | `ace-agent-secret-<experimentID>` |
| Contains | LLM API key | Other agent secrets (PagerDuty, JIRA, etc.) |
| Scoped to | Project (shared across all experiments using this model) | Experiment (specific experiment, reused across runs) |
| Created when | User saves Model Config | User saves Experiment |
| Deleted when | User deletes Model Config | User deletes Experiment |
| Referenced by | LiteLLM sidecar upstream routing | `envFrom.secretRef` in agent container |

---

## Provider → LiteLLM Model String Mapping

| Provider | Model field format | Example |
|---|---|---|
| openai | `openai/<model>` | `openai/gpt-4o` |
| anthropic | `anthropic/<model>` | `anthropic/claude-3-5-sonnet-20241022` |
| google | `google/<model>` | `google/gemini-1.5-pro` |
| azure | `azure/<deployment>` | `azure/my-gpt4-deploy` |
| ollama | `ollama/<model>` | `ollama/llama3.1:70b` |
| custom | `openai/<model>` | `openai/custom-model` |

---

**Last Updated:** 2026-07-07
