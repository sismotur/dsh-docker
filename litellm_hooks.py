"""LiteLLM proxy hooks for dsh-docker.

dsh's deepseek-official adapter often requests max_tokens on the order of
the full provider context (e.g. 256000). TensorFold rejects requests where
prompt + max_tokens exceeds its --context budget. Clamp completion tokens
before the upstream call.

dsh may also advertise OpenAI built-in tools such as web_search_preview.
Local TensorFold only accepts classic function tools — strip unsupported
tool entries so chat/completions reach the model.
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

# OpenAI "built-in" tool types TensorFold rejects.
UNSUPPORTED_TOOL_TYPES = frozenset(
    {
        "web_search_preview",
        "web_search",
        "file_search",
        "code_interpreter",
        "computer",
        "computer_use_preview",
        "image_generation",
        "mcp",
    }
)


def _tool_type(tool: Any) -> str | None:
    if not isinstance(tool, dict):
        return None
    t = tool.get("type")
    if isinstance(t, str):
        return t
    return None


def _is_function_tool(tool: Any) -> bool:
    """Keep classic function / tools API shapes TensorFold can run."""
    if not isinstance(tool, dict):
        return False
    t = _tool_type(tool)
    if t in UNSUPPORTED_TOOL_TYPES:
        return False
    # OpenAI chat: {"type":"function","function":{...}}
    if t == "function":
        return True
    # Some stacks omit type and only send {"function": {...}}
    if t is None and isinstance(tool.get("function"), dict):
        return True
    # Legacy name/description/parameters at top level
    if t is None and "name" in tool and ("parameters" in tool or "description" in tool):
        return True
    # Unknown type — drop for local TF rather than 400
    if t is not None and t not in ("function",):
        return False
    return t == "function" or isinstance(tool.get("function"), dict)


def _strip_unsupported_tools(data: dict) -> None:
    for key in ("tools", "functions"):
        tools = data.get(key)
        if not isinstance(tools, list) or not tools:
            continue
        if key == "functions":
            # legacy functions array is already function-shaped; keep as-is
            continue
        kept = [t for t in tools if _is_function_tool(t)]
        if len(kept) == len(tools):
            continue
        if kept:
            data[key] = kept
        else:
            data.pop(key, None)
            tc = data.get("tool_choice")
            if tc not in (None, "none", "auto"):
                data.pop("tool_choice", None)
            else:
                data.pop("tool_choice", None)


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

        # Always strip built-in tool types for local OpenAI-compatible backends.
        if model in TENSORFOLD_MODELS or True:
            _strip_unsupported_tools(data)

        for key in ("max_tokens", "max_completion_tokens"):
            if key not in data or data[key] is None:
                continue
            try:
                val = int(data[key])
            except (TypeError, ValueError):
                continue
            if val > MAX_COMPLETION_TOKENS:
                data[key] = MAX_COMPLETION_TOKENS

        if model in TENSORFOLD_MODELS:
            if data.get("max_tokens") is None and data.get("max_completion_tokens") is None:
                data["max_tokens"] = min(8192, MAX_COMPLETION_TOKENS)

        return data


proxy_handler_instance = DshLocalClamp()
