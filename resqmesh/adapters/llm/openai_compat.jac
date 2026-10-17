"""One HTTP adapter for every hosted provider.

Gemini, Groq, DeepSeek and Ollama all expose an OpenAI-compatible
`/chat/completions` endpoint, so a single client over plain `httpx` serves the
whole chain. No vendor SDKs: fewer dependencies, one code path to test, and adding
a provider is a configuration entry rather than new code.

This layer only moves bytes and classifies failures. Retrying, failover, circuit
breaking and schema repair live in `resqmesh.adapters.llm.router`.
"""

import base64;
import mimetypes;
import httpx;
import from pathlib { Path }
import from resqmesh.contracts.enums { LLMProvider }

"""A provider call failed. `retryable` says whether trying again could help."""
class ProviderError(RuntimeError) {
    has provider: LLMProvider,
        retryable: bool,
        status: int | None;

    def init(self: ProviderError, provider: LLMProvider, message: str, retryable: bool, status: int | None = None) {
        super.init(f"{provider.value}: {message}");
        self.provider = provider;
        self.retryable = retryable;
        self.status = status;
    }
}

"""Worth retrying: rate limits and transient server trouble. Everything else in the
4xx range (bad key, unknown model, malformed request) will fail identically on a
retry, so the router moves straight on to the next provider."""
glob RETRYABLE_STATUS: frozenset[int] = frozenset({408, 409, 425, 429, 500, 502, 503, 504});

"""Where a provider lives and which models to ask for."""
obj ProviderSpec {
    has name: LLMProvider,
        base_url: str,
        model: str,
        api_key: str | None = None,
        # Model to use for photographs, or None if this provider cannot see.
        vision_model: str | None = None,
        timeout_s: float = 20.0;

    def supports_vision -> bool {
        return self.vision_model is not None;
    }
}

"""A local image as a `data:` URL, the form every compatible endpoint accepts inline."""
def image_data_url(image_path: str | Path) -> str {
    path = Path(image_path);
    mime = mimetypes.guess_type(path.name)[0] or "image/jpeg";
    return f"data:{mime};base64,{base64.b64encode(path.read_bytes()).decode('ascii')}";
}

"""One provider endpoint. `transport` (e.g. `httpx.MockTransport`) or a ready
`client` can be injected; with neither, calls go to the real network."""
obj ChatProvider {
    has spec: ProviderSpec,
        transport: httpx.BaseTransport | None = None,
        client: httpx.Client | None = None;

    def name -> LLMProvider {
        return self.spec.name;
    }

    def http -> httpx.Client {
        if self.client is None {
            headers: dict[str, str] = {"Authorization": f"Bearer {self.spec.api_key}"} if self.spec.api_key else {};
            self.client = httpx.Client(timeout=self.spec.timeout_s, headers=headers, transport=self.transport);
        }
        return self.client;
    }

    """One chat completion. Returns the assistant text or raises `ProviderError`."""
    def complete(
        messages: list[dict[str, any]],
        json_mode: bool,
        vision: bool = False,
        max_tokens: int = 1024
    ) -> str {
        model = self.spec.vision_model if vision else self.spec.model;
        if model is None {
            raise ProviderError(self.name(), "no vision model configured", retryable=False);
        }
        body: dict[str, any] = {
            "model": model,
            "messages": messages,
            "temperature": 0,  # extraction, not creativity: same report, same answer
            "max_tokens": max_tokens
        };
        if json_mode {
            body["response_format"] = {"type": "json_object"};
        }

        url = f"{self.spec.base_url.rstrip('/')}/chat/completions";
        response: any = None;
        try {
            response = self.http().post(url, json=body);
        } except httpx.TimeoutException as exc {
            raise ProviderError(self.name(), "timed out", retryable=True) from exc;
        } except httpx.TransportError as exc {
            # DNS, refused, reset: the network is the problem
            raise ProviderError(self.name(), f"unreachable ({exc.__class__.__name__})", retryable=True) from exc;
        }

        if response.status_code != 200 {
            raise ProviderError(
                self.name(),
                f"HTTP {response.status_code}: {self.error_message(response)}",
                retryable=response.status_code in RETRYABLE_STATUS,
                status=response.status_code
            );
        }
        content: any = None;
        try {
            content = response.json()["choices"][0]["message"]["content"];
        } except (ValueError, KeyError, IndexError, TypeError) as exc {
            raise ProviderError(self.name(), "unexpected response shape", retryable=False) from exc;
        }
        if not isinstance(content, str) or not content.strip() {
            raise ProviderError(self.name(), "empty completion", retryable=True);
        }
        return content;
    }

    """The provider's own explanation, e.g. "model ... is no longer available".

    Without it a retired model and a wrong URL are the same opaque 404. Google
    wraps errors in a list, OpenAI-style APIs do not; handle both. The key is
    redacted in case a provider ever echoes it back.
    """
    def error_message(response: httpx.Response) -> str {
        message = "";
        try {
            body: any = response.json();
            if isinstance(body, list) and body {
                body = body[0];
            }
            message = str(body.get("error", {}).get("message", "")) if isinstance(body, dict) else "";
        } except ValueError {
            message = response.text;
        }
        message = " ".join(message.split())[:200];
        if self.spec.api_key {
            message = message.replace(self.spec.api_key, "<key>");
        }
        return message or "no detail";
    }

    def close {
        if self.client is not None {
            self.client.close();
            self.client = None;
        }
    }
}
