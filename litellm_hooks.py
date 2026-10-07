"""LiteLLM proxy hooks for dsh-docker.

1) Clamp oversized max_tokens from dsh.
2) Strip OpenAI/Anthropic built-in tool types (web_search_preview, etc.)
   that TensorFold rejects ("function tools only").
"""

from __future__ import annotations

from typing import Any

from litellm.integrations.custom_logger import CustomLogger

MAX_COMPLETION_TOKENS = 24576

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

UNSUPPORTED_TOOL_TYPES = frozenset(
    {
        "web_search_preview",
        "web_search",
        "web_search_20250305",
        "file_search",
        "code_interpreter",
        "computer",
        "computer_use_preview",
        "image_generation",
        "mcp",
        "server_tool_use",
    }
)


def _tool_type(tool: Any) -> str | None:
    if isinstance(tool, dict):
        t = tool.get("type")
        return t if isinstance(t, str) else None
    return None


def _is_function_tool(tool: Any) -> bool:
    if not isinstance(tool, dict):
        return False
    t = _tool_type(tool)
    if t is not None and t in UNSUPPORTED_TOOL_TYPES:
        return False
    if t == "function":
        return True
    if t is None and isinstance(tool.get("function"), dict):
        return True
    # Anthropic classic tools: name + input_schema, no type
    if t is None and "name" in tool and ("input_schema" in tool or "parameters" in tool):
        return True
    if t is not None and t not in ("function",):
        return False
    return isinstance(tool.get("function"), dict)


def _strip_tools_list(tools: list) -> list | None:
    kept = [t for t in tools if _is_function_tool(t)]
    return kept


def _strip_unsupported_tools_in(obj: Any) -> Any:
    """Recursively strip unsupported tools from request payloads."""
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if k == "tools" and isinstance(v, list):
                kept = _strip_tools_list(v)
                if kept:
                    out[k] = kept
                # drop empty tools
                continue
            if k == "tool_choice" and isinstance(v, (str, dict)):
                # defer; fix after tools known
                out[k] = v
                continue
            out[k] = _strip_unsupported_tools_in(v)
        # clean tool_choice if no tools left
        if "tool_choice" in out and not out.get("tools"):
            tc = out.get("tool_choice")
            if tc not in (None, "none", "auto"):
                out.pop("tool_choice", None)
            else:
                out.pop("tool_choice", None)
        return out
    if isinstance(obj, list):
        return [_strip_unsupported_tools_in(x) for x in obj]
    return obj


def _clamp_max_tokens(data: dict) -> None:
    model = str(data.get("model") or "")
    for key in ("max_tokens", "max_completion_tokens", "max_output_tokens"):
        if key not in data or data[key] is None:
            continue
        try:
            val = int(data[key])
        except (TypeError, ValueError):
            continue
        if val > MAX_COMPLETION_TOKENS:
            data[key] = MAX_COMPLETION_TOKENS
    if model in TENSORFOLD_MODELS:
        if (
            data.get("max_tokens") is None
            and data.get("max_completion_tokens") is None
            and data.get("max_output_tokens") is None
        ):
            data["max_tokens"] = min(8192, MAX_COMPLETION_TOKENS)


def _mutate_request(data: dict) -> dict:
    if not isinstance(data, dict):
        return data
    cleaned = _strip_unsupported_tools_in(data)
    if isinstance(cleaned, dict):
        _clamp_max_tokens(cleaned)
        # mutate original in place so LiteLLM sees changes
        data.clear()
        data.update(cleaned)
    return data


class DshLocalClamp(CustomLogger):
    async def async_pre_call_hook(
        self,
        user_api_key_dict: Any,
        cache: Any,
        data: dict,
        call_type: str,
    ) -> Any:
        return _mutate_request(data) if isinstance(data, dict) else data

    async def async_pre_request_hook(
        self,
        user_api_key_dict: Any = None,
        cache: Any = None,
        data: dict | None = None,
        call_type: str | None = None,
        **kwargs: Any,
    ) -> Any:
        if isinstance(data, dict):
            return _mutate_request(data)
        # some litellm versions pass payload in kwargs
        for key in ("data", "request_data", "optional_params"):
            if isinstance(kwargs.get(key), dict):
                _mutate_request(kwargs[key])
        return data

    async def async_pre_call_deployment_hook(
        self,
        kwargs: dict,
        call_type: str | None = None,
        **rest: Any,
    ) -> Any:
        if isinstance(kwargs, dict):
            if isinstance(kwargs.get("messages"), list) or "tools" in kwargs:
                _mutate_request(kwargs)
            # litellm often nests under kwargs["optional_params"] or litellm_params
            for key in ("optional_params", "litellm_params", "model_call_details", "additional_args"):
                val = kwargs.get(key)
                if isinstance(val, dict):
                    _mutate_request(val)
                    if isinstance(val.get("tools"), list):
                        _mutate_request(val)
        return kwargs

    def log_pre_api_call(self, model: str, messages: Any, kwargs: dict) -> None:
        # sync path used by some code paths
        if isinstance(kwargs, dict):
            if "tools" in kwargs:
                _mutate_request(kwargs)
            op = kwargs.get("optional_params")
            if isinstance(op, dict):
                _mutate_request(op)

    async def async_log_pre_api_call(self, model: str, messages: Any, kwargs: dict) -> None:
        self.log_pre_api_call(model, messages, kwargs)


proxy_handler_instance = DshLocalClamp()
