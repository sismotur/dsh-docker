## Local LLM — TensorFold

Both backends start with dsh (and at login via LaunchAgents).

| Role | URL | Model id |
| --- | --- | --- |
| **Default / fastest** (`smart-router`) | `http://127.0.0.1:8425/v1` | `tf-nemotron` |
| Alternate quality | `http://127.0.0.1:8423/v1` | `tf-qwen38` |

Default agent model: **`smart-router` → Nemotron**.
Pick `tf-qwen38` in the UI when you want the Qwen path (131k + DFlash2).

Docs: `~/models/tensorfold/README.md`.
