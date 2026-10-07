"""LiteLLM proxy hooks for dsh-docker.

dsh's deepseek-official adapter often requests max_tokens on the order of
the full provider context (e.g. 256000). TensorFold rejects requests where
prompt + max_tokens exceeds its --context budget. Clamp completion tokens
before the upstream call.
"""

from __future__ import annotations

from typing import Any

from litellm.integrations.custom_logger import CustomLogger

# Hard ceiling for completion tokens sent to local backends.
# TensorFold omlx-qwen36 runs with --context 131072; leave headroom for
# prompt + chat template + tools. 24k output is enough for agent turns.
MAX_COMPLETION_TOKENS = 24576

# Models that talk to TensorFold (:8421 fast MoE, :8423 Qwen3.8+DFlash2).
TENSORFOLD_MODELS = frozenset(
    {
        "omlx-qwen36",
        "Qwen3.6-35B-A3B-4bit",
        "qwen36-35b-4bit",
        "tf-qwen38",
        "Qwen3.8-27B-OptiQ-4bit",
        "qwen38-27b-optiq-4bit",
        "smart-router",
    }
)


class DshLocalClamp(CustomLogger):
    async def async_pre_call_hook(
        self,
        user_api_key_dict: Any,
        cache: Any,
        data: dict,
        call_type: str,
    ) -> Any:
        if not isinstance(data, dict):
            return data

        model = str(data.get("model") or "")
        # Always clamp absurd completion budgets; TF models especially.
        force = model in TENSORFOLD_MODELS or True
        if not force:
            return data

        for key in ("max_tokens", "max_completion_tokens"):
            if key not in data or data[key] is None:
                continue
            try:
                val = int(data[key])
            except (TypeError, ValueError):
                continue
            if val > MAX_COMPLETION_TOKENS:
                data[key] = MAX_COMPLETION_TOKENS

        # If client omitted max_tokens, set a sane default for local TF.
        if model in TENSORFOLD_MODELS:
            if data.get("max_tokens") is None and data.get("max_completion_tokens") is None:
                data["max_tokens"] = min(8192, MAX_COMPLETION_TOKENS)

        return data


proxy_handler_instance = DshLocalClamp()
