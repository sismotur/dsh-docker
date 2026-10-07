"""LiteLLM proxy hooks for dsh-docker.

1) Clamp oversized max_tokens from dsh.
2) Strip OpenAI/Anthropic built-in tool types (web_search_preview, etc.)
   that TensorFold rejects ("function tools only").
3) Force Qwen chat_template_kwargs.enable_thinking=false for TensorFold.
4) Sanitize Anthropic Messages SSE so content_block_stop is deferred until
   message settlement. TensorFold/LiteLLM can emit stop then late tool arg
   deltas on the same index; dsh-llm-deepseek rejects that as
   MALFORMED_RESPONSE ("delta/stop without an open block").
"""

from __future__ import annotations

from collections import deque
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


def _is_tensorfold_model(model: str) -> bool:
    if model in TENSORFOLD_MODELS:
        return True
    base = model.split("/")[-1] if model else ""
    return base in TENSORFOLD_MODELS


def _force_thinking_off(data: dict) -> None:
    """Disable Qwen thinking for TensorFold (chat + responses paths)."""
    model = str(data.get("model") or "")
    if not _is_tensorfold_model(model):
        return

    def _set_kwargs(target: dict) -> None:
        ctk = target.get("chat_template_kwargs")
        if not isinstance(ctk, dict):
            ctk = {}
            target["chat_template_kwargs"] = ctk
        ctk["enable_thinking"] = False

    _set_kwargs(data)
    extra = data.get("extra_body")
    if not isinstance(extra, dict):
        extra = {}
        data["extra_body"] = extra
    _set_kwargs(extra)
    for nest_key in ("optional_params", "litellm_params", "additional_args"):
        nest = data.get(nest_key)
        if isinstance(nest, dict):
            _set_kwargs(nest)
            nest_extra = nest.get("extra_body")
            if isinstance(nest_extra, dict):
                _set_kwargs(nest_extra)
            elif "extra_body" not in nest:
                nest["extra_body"] = {"chat_template_kwargs": {"enable_thinking": False}}


def _mutate_request(data: dict) -> dict:
    if not isinstance(data, dict):
        return data
    cleaned = _strip_unsupported_tools_in(data)
    if isinstance(cleaned, dict):
        _clamp_max_tokens(cleaned)
        _force_thinking_off(cleaned)
        # mutate original in place so LiteLLM sees changes
        data.clear()
        data.update(cleaned)
    return data


# ---------------------------------------------------------------------------
# Anthropic Messages stream sanitizer
# ---------------------------------------------------------------------------


class AnthropicBlockStopSanitizer:
    """Defer content_block_stop until message settlement.

    dsh-llm-deepseek tracks blocks by index and rejects delta/stop after a
    block is closed. LiteLLM's Responses→Anthropic adapter can emit
    content_block_stop for a tool_use item before late
    function_call_arguments.delta chunks for the same index (seen with
    multi-tool / interleaved text+tool TF streams). Holding stops until
    message_delta/message_stop keeps those late deltas valid.
    """

    def __init__(self) -> None:
        self._deferred_stops: dict[int, dict[str, Any]] = {}

    def feed(self, chunk: Any) -> list[Any]:
        if not isinstance(chunk, dict):
            return [chunk]
        t = chunk.get("type")
        if t == "content_block_stop":
            idx = chunk.get("index")
            if isinstance(idx, int):
                self._deferred_stops[idx] = chunk
                return []
            return [chunk]
        if t in ("message_delta", "message_stop"):
            out = self.flush_stops()
            out.append(chunk)
            return out
        return [chunk]

    def flush_stops(self) -> list[dict[str, Any]]:
        if not self._deferred_stops:
            return []
        out = [self._deferred_stops[i] for i in sorted(self._deferred_stops)]
        self._deferred_stops.clear()
        return out

    def flush_all(self) -> list[Any]:
        return self.flush_stops()


def _install_responses_stream_sanitizer() -> None:
    """Monkeypatch LiteLLM Responses→Anthropic wrapper to sanitize block stops."""
    try:
        from litellm.llms.anthropic.experimental_pass_through.responses_adapters.streaming_iterator import (
            AnthropicResponsesStreamWrapper,
        )
    except Exception:
        return

    if getattr(AnthropicResponsesStreamWrapper, "_dsh_stop_sanitizer_installed", False):
        return

    _orig_anext = AnthropicResponsesStreamWrapper.__anext__

    async def _sanitized_anext(self: Any) -> Any:
        san = getattr(self, "_dsh_block_sanitizer", None)
        if san is None:
            san = AnthropicBlockStopSanitizer()
            self._dsh_block_sanitizer = san
            self._dsh_sanitizer_pending: deque = deque()

        pending: deque = self._dsh_sanitizer_pending
        if pending:
            return pending.popleft()

        while True:
            try:
                chunk = await _orig_anext(self)
            except StopAsyncIteration:
                for c in san.flush_all():
                    pending.append(c)
                if pending:
                    return pending.popleft()
                raise

            emitted = san.feed(chunk)
            if not emitted:
                continue
            first, *rest = emitted
            for c in rest:
                pending.append(c)
            return first

    AnthropicResponsesStreamWrapper.__anext__ = _sanitized_anext  # type: ignore[method-assign]
    AnthropicResponsesStreamWrapper._dsh_stop_sanitizer_installed = True

    # TensorFold emits response.reasoning_text.*; LiteLLM only handles summary.
    _orig_process = AnthropicResponsesStreamWrapper._process_event

    def _process_event_with_tf_reasoning(self: Any, event: Any) -> None:
        event_type = getattr(event, "type", None)
        if event_type is None and isinstance(event, dict):
            event_type = event.get("type")
        if isinstance(event_type, str) and event_type.startswith("response.reasoning_text."):
            alias = "response.reasoning_summary_text." + event_type[len("response.reasoning_text.") :]
            if isinstance(event, dict):
                event = dict(event)
                event["type"] = alias
            else:
                try:
                    setattr(event, "type", alias)
                except Exception:
                    pass
        return _orig_process(self, event)

    AnthropicResponsesStreamWrapper._process_event = _process_event_with_tf_reasoning  # type: ignore[method-assign]


_install_responses_stream_sanitizer()


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
            for key in ("optional_params", "litellm_params", "model_call_details", "additional_args"):
                val = kwargs.get(key)
                if isinstance(val, dict):
                    _mutate_request(val)
                    if isinstance(val.get("tools"), list):
                        _mutate_request(val)
        return kwargs

    def log_pre_api_call(self, model: str, messages: Any, kwargs: dict) -> None:
        if isinstance(kwargs, dict):
            if "tools" in kwargs:
                _mutate_request(kwargs)
            op = kwargs.get("optional_params")
            if isinstance(op, dict):
                _mutate_request(op)
            if model and "model" not in kwargs:
                tmp = {"model": model, **kwargs}
                _mutate_request(tmp)
                for k in ("extra_body", "chat_template_kwargs"):
                    if k in tmp:
                        kwargs[k] = tmp[k]

    async def async_log_pre_api_call(self, model: str, messages: Any, kwargs: dict) -> None:
        self.log_pre_api_call(model, messages, kwargs)


proxy_handler_instance = DshLocalClamp()
