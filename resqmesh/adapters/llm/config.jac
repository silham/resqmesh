"""Build the provider chain from the environment.

The chain order is configuration, not code, so switching DeepSeek in during a
demo, or promoting it, is an `.env` change:

    RESQMESH_LLM_ORDER=gemini,groq,deepseek     # the default
    GEMINI_API_KEY=...                          # free tier, primary, reads photos
    GROQ_API_KEY=...                            # free tier failover, text only
    DEEPSEEK_API_KEY=...                        # paid: only used if a key is set
    RESQMESH_OFFLINE=1                          # skip every hosted provider

A provider named in the order but lacking its key is skipped, not an error: a
teammate with only a Gemini key still gets a working chain. Ollama is supported
but not in the default order (Change Log: no hardware for local inference); add
`ollama` to the order on a machine that can run it.
"""

import os;
import from resqmesh.adapters.llm.openai_compat { ChatProvider, ProviderSpec }
import from resqmesh.adapters.llm.router { ProviderRouter, RouterConfig }
import from resqmesh.contracts.enums { LLMProvider }

glob DEFAULT_ORDER: str = "gemini,groq,deepseek";

"""One provider's key variable, endpoint and models."""
obj KnownProvider {
    has key_env: str | None,
        base_url: str,
        model: str,
        vision_model: str | None;
}

"""Endpoints and default models. Every model id can be overridden by env."""
def known_providers(env: Mapping[str, str]) -> dict[LLMProvider, KnownProvider] {
    return {
        LLMProvider.GEMINI: KnownProvider(
            key_env="GEMINI_API_KEY",
            base_url="https://generativelanguage.googleapis.com/v1beta/openai",
            # gemini-2.5-flash (the proposal's model) is retired for new accounts.
            model=env.get("RESQMESH_GEMINI_MODEL", "gemini-3.6-flash"),
            vision_model=env.get("RESQMESH_GEMINI_MODEL", "gemini-3.6-flash")
        ),
        LLMProvider.GROQ: KnownProvider(
            key_env="GROQ_API_KEY",
            base_url="https://api.groq.com/openai/v1",
            # llama-3.3-70b-versatile (the proposal's model) is no longer served.
            model=env.get("RESQMESH_GROQ_MODEL", "openai/gpt-oss-120b"),
            vision_model=None  # text only
        ),
        LLMProvider.DEEPSEEK: KnownProvider(
            key_env="DEEPSEEK_API_KEY",
            base_url=env.get("RESQMESH_DEEPSEEK_BASE_URL", "https://api.deepseek.com"),
            model=env.get("RESQMESH_DEEPSEEK_MODEL", "deepseek-flash"),
            vision_model=env.get(
                "RESQMESH_DEEPSEEK_VISION_MODEL", env.get("RESQMESH_DEEPSEEK_MODEL", "deepseek-flash")
            )
        ),
        LLMProvider.OLLAMA: KnownProvider(
            key_env=None,
            base_url=env.get("OLLAMA_BASE_URL", "http://localhost:11434").rstrip("/") + "/v1",
            model=env.get("RESQMESH_OLLAMA_MODEL", "llama3.2:3b"),
            vision_model=None
        )
    };
}

"""What `router_from_env` built, and what it skipped and why."""
obj ChainPlan {
    has active: list[LLMProvider],
        skipped: list[tuple[str, str]];
}

def truthy(value: str | None) -> bool {
    return (value or "").strip().lower() in {"1", "true", "yes", "on"};
}

"""The provider specs the environment asks for, in order, plus the plan."""
def plan_chain(env: Mapping[str, str] | None = None) -> tuple[list[ProviderSpec], ChainPlan] {
    source: Mapping[str, str] = os.environ if env is None else env;
    if truthy(source.get("RESQMESH_OFFLINE")) {
        return ([], ChainPlan(active=[], skipped=[("*", "RESQMESH_OFFLINE is set")]));
    }

    known = known_providers(source);
    specs: list[ProviderSpec] = [];
    skipped: list[tuple[str, str]] = [];
    for raw in source.get("RESQMESH_LLM_ORDER", DEFAULT_ORDER).split(",") {
        name = raw.strip().lower();
        if not name {
            continue;
        }
        provider: LLMProvider = LLMProvider.RULES;
        try {
            provider = LLMProvider(name);
        } except ValueError {
            skipped.append((name, "unknown provider"));
            continue;
        }
        if provider not in known {
            skipped.append((name, "unknown provider"));
            continue;
        }
        info = known[provider];
        key: str | None = source.get(info.key_env, "").strip() if info.key_env else None;
        if info.key_env and not key {
            skipped.append((name, f"{info.key_env} not set"));
            continue;
        }
        specs.append(ProviderSpec(
            name=provider, base_url=info.base_url, model=info.model, api_key=key, vision_model=info.vision_model
        ));
    }
    return (specs, ChainPlan(active=[s.name for s in specs], skipped=skipped));
}

"""The production `LLMPort`. Always usable: with no keys it is offline rules only."""
def router_from_env(
    env: Mapping[str, str] | None = None, config: RouterConfig | None = None
) -> tuple[ProviderRouter, ChainPlan] {
    (specs, plan) = plan_chain(env);
    router = ProviderRouter(providers=[ChatProvider(spec=s) for s in specs], config=config or RouterConfig());
    return (router, plan);
}
