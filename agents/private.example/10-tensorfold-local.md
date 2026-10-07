## Local LLM — TensorFold (example)

<!-- Copy to agents/private/10-tensorfold-local.md and fill real URLs/models.
     Example only — not seeded. -->

Primary local inference is **TensorFold** (OpenAI-compatible).

| Role | URL | Model id |
| --- | --- | --- |
| Fast | `http://127.0.0.1:PORT_FAST/v1` | `YOUR_FAST_MODEL_ID` |
| Quality (optional) | `http://127.0.0.1:PORT_QUALITY/v1` | `YOUR_QUALITY_MODEL_ID` |

dsh reaches models via LiteLLM (`http://litellm:4000/v1`). Default router
model: `smart-router` → fast TensorFold backend.

Do not default to Ollama or other local servers unless the user asks.
