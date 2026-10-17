"""The provider router: the `LLMPort` the rest of the system actually talks to.

Proposal section 4.3, "How failures are handled", implemented as written:

* every call has a **timeout** (on the provider) and a **bounded retry with
  exponential backoff**, for failures that retrying can fix;
* every provider has a **circuit breaker**: after repeated consecutive failures
  the router stops calling it for a cooldown, then lets one probe through;
* a reply that does not validate gets **one repair attempt**, then the router
  **escalates** to the next provider; malformed output is never coerced;
* when every hosted provider is gone, the deterministic `RuleBasedExtractor`
  answers.

"The system is designed so that no single failure produces silence; it produces a
stated, lower-confidence answer." Every result names the tier that produced it.

Report text is never logged here. It has already been pseudonymised by A1, but
logs outlive incidents and have no business holding what people reported.
"""

import json;
import logging;
import time;
import from resqmesh.adapters.llm.prompts { EXTRACTION_SYSTEM, VISION_SYSTEM, REPAIR_TEMPLATE, extraction_user }
import from resqmesh.adapters.llm.openai_compat { ChatProvider, ProviderError, image_data_url }
import from resqmesh.adapters.llm.rules { ProviderUnavailable, RuleBasedExtractor }
import from resqmesh.contracts.enums { LLMProvider }
import from resqmesh.contracts.ports { ExtractionResult, LLMPort }

glob log: logging.Logger = logging.getLogger("resqmesh.adapters.llm.router");

obj RouterConfig {
    # Retries after the first attempt, for retryable failures only.
    has max_retries: int = 2,
        backoff_base_s: float = 0.5,
        # Consecutive failed calls before a provider's breaker opens.
        breaker_threshold: int = 3,
        breaker_cooldown_s: float = 60.0;
}

obj Breaker {
    has failures: int = 0,
        open_until: float = 0.0;

    def is_open(now: float) -> bool {
        # Past the cooldown the breaker is half-open: one call goes through, and
        # its outcome either closes the breaker or re-opens it for another cooldown.
        return now < self.open_until;
    }
}

obj ProviderHealth {
    has provider: LLMProvider,
        open: bool,
        consecutive_failures: int,
        vision: bool;
}

"""A validation error as one line for the repair prompt. A validator may carry one
entry per bad field; the model is shown the first five."""
def describe_problem(exc: any) -> str {
    detail = "";
    if exc.args and isinstance(exc.args[0], (list, tuple)) {
        detail = "; ".join([str(e) for e in list(exc.args[0])[:5]]);
    } else {
        detail = " ".join(str(exc).split());
    }
    return detail or exc.__class__.__name__;
}

"""Why `payload` does not satisfy `schema`, or None if it does.

A schema with a static `from_payload` validator is asked to build itself from the
payload and any error it raises is the reason. `dict` accepts any JSON object.
"""
def schema_problem(payload: dict[str, any], schema: any) -> str | None {
    if schema is dict {
        return None;
    }
    if not hasattr(schema, "from_payload") {
        return None;
    }
    try {
        schema.from_payload(payload);
    } except (ValueError, TypeError, KeyError) as exc {
        return describe_problem(exc);
    }
    return None;
}

"""`(payload, None)` when the reply validates, `(None, reason)` when it does not."""
def parse_reply(content: str, schema: any) -> tuple[dict[str, any] | None, str | None] {
    payload: any = None;
    try {
        payload = json.loads(content);
    } except json.JSONDecodeError as exc {
        return (None, f"not valid JSON ({exc.msg})");
    }
    if not isinstance(payload, dict) {
        return (None, "top level must be a JSON object");
    }
    problem = schema_problem(payload, schema);
    if problem is not None {
        return (None, problem);
    }
    return (payload, None);
}

"""Requests the router was asked for, and those no provider could satisfy.

Counted per *request*, not per HTTP attempt: a provider that fails and is
covered by the next one in the chain is the failover working, not a failed
call. `unrecovered` counts only the requests that walked the whole chain
without a usable reply and had to fall back (or raise).
"""
obj RouterTally {
    has requests: int = 0,
        unrecovered: int = 0;
}

"""The production `LLMPort`: hosted providers in order, then offline rules."""
obj ProviderRouter(LLMPort) {
    has providers: list[ChatProvider],
        fallback: RuleBasedExtractor = RuleBasedExtractor(),
        config: RouterConfig = RouterConfig(),
        sleep: Callable[[float], None] = time.sleep,
        clock: Callable[[], float] = time.monotonic,
        # Rebuilt in postinit: one breaker per provider, one tally per router.
        breakers: dict[LLMProvider, Breaker] = {},
        tally: RouterTally = RouterTally();

    def postinit {
        self.breakers = {p.name(): Breaker() for p in self.providers};
        self.tally = RouterTally();
    }

    # -- health ---------------------------------------------------------------

    """Per-provider state, for the console's degraded-mode indicator."""
    def health -> list[ProviderHealth] {
        now = self.clock();
        return [
            ProviderHealth(
                provider=p.name(),
                open=self.breakers[p.name()].is_open(now),
                consecutive_failures=self.breakers[p.name()].failures,
                vision=p.spec.supports_vision()
            )
            for p in self.providers
        ];
    }

    def available(vision: bool) -> list[ChatProvider] {
        now = self.clock();
        return [
            p for p in self.providers
            if not self.breakers[p.name()].is_open(now) and (p.spec.supports_vision() or not vision)
        ];
    }

    # -- one provider, with retry and breaker bookkeeping ---------------------

    def call(
        provider: ChatProvider,
        messages: list[dict[str, any]],
        json_mode: bool,
        vision: bool = False,
        max_tokens: int = 1024
    ) -> str {
        breaker = self.breakers[provider.name()];
        attempt = 0;
        while True {
            content = "";
            try {
                content = provider.complete(messages, json_mode=json_mode, vision=vision, max_tokens=max_tokens);
            } except ProviderError as exc {
                if exc.retryable and attempt < self.config.max_retries {
                    delay = self.config.backoff_base_s * (2 ** attempt);
                    log.warning("llm %s: %s; retry %d in %.1fs", provider.name().value, exc, attempt + 1, delay);
                    self.sleep(delay);
                    attempt += 1;
                    continue;
                }
                breaker.failures += 1;
                if breaker.failures >= self.config.breaker_threshold {
                    breaker.open_until = self.clock() + self.config.breaker_cooldown_s;
                    log.error(
                        "llm %s: circuit open for %.0fs after %d failures",
                        provider.name().value, self.config.breaker_cooldown_s, breaker.failures
                    );
                } else {
                    log.warning("llm %s: failed (%s); failing over", provider.name().value, exc);
                }
                raise;
            }
            breaker.failures = 0;
            breaker.open_until = 0.0;
            return content;
        }
    }

    """Walk the chain for a schema-valid reply. None if every provider fails."""
    def structured(messages: list[dict[str, any]], schema: any, vision: bool) -> ExtractionResult | None {
        self.tally.requests += 1;
        for provider in self.available(vision=vision) {
            started = time.perf_counter();
            content = "";
            try {
                content = self.call(provider, messages, json_mode=True, vision=vision);
            } except ProviderError {
                continue;
            }
            (payload, problem) = parse_reply(content, schema);
            repaired = False;
            if problem is not None {
                # One repair attempt on the same provider, showing it exactly what failed.
                log.warning("llm %s: invalid reply (%s); one repair attempt", provider.name().value, problem);
                repair = [
                    *messages,
                    {"role": "assistant", "content": content},
                    {"role": "user", "content": REPAIR_TEMPLATE.format(error=problem)}
                ];
                try {
                    content = self.call(provider, repair, json_mode=True, vision=vision);
                } except ProviderError {
                    continue;
                }
                (payload, problem) = parse_reply(content, schema);
                repaired = True;
            }
            if problem is not None or payload is None {
                log.warning("llm %s: still invalid after repair; escalating", provider.name().value);
                continue;
            }
            return ExtractionResult(
                payload=payload,
                provider=provider.name(),
                repaired=repaired,
                latency_ms=round((time.perf_counter() - started) * 1000, 1)
            );
        }
        self.tally.unrecovered += 1;
        return None;
    }

    # -- LLMPort --------------------------------------------------------------

    override def extract(text: str, schema: type, lang_hint: str = "unknown") -> ExtractionResult {
        messages: list[dict[str, any]] = [
            {"role": "system", "content": EXTRACTION_SYSTEM},
            {"role": "user", "content": extraction_user(text, lang_hint)}
        ];
        result = self.structured(messages, schema, vision=False);
        if result is not None {
            return result;
        }
        log.error("llm: every hosted provider failed; deterministic offline extraction");
        return self.fallback.extract(text, schema, lang_hint=lang_hint);
    }

    """Read a damage photograph. Raises `ProviderUnavailable` if nothing can see.

    There is no deterministic fallback for a photograph, and an unread photo is
    safer than an invented severity: its contribution to priority is bounded.
    """
    override def vision(image_path: str, schema: type) -> ExtractionResult {
        messages: list[dict[str, any]] = [
            {"role": "system", "content": VISION_SYSTEM},
            {"role": "user", "content": [
                {"type": "text", "text": "Assess this photograph."},
                {"type": "image_url", "image_url": {"url": image_data_url(image_path)}}
            ]}
        ];
        result = self.structured(messages, schema, vision=True);
        if result is None {
            raise ProviderUnavailable("no vision-capable provider reachable; photo left unread");
        }
        return result;
    }

    override def draft(prompt: str, max_tokens: int = 512) -> ExtractionResult {
        messages: list[dict[str, any]] = [{"role": "user", "content": prompt}];
        self.tally.requests += 1;
        for provider in self.available(vision=False) {
            started = time.perf_counter();
            text = "";
            try {
                text = self.call(provider, messages, json_mode=False, max_tokens=max_tokens);
            } except ProviderError {
                continue;
            }
            return ExtractionResult(
                payload={"text": text},
                provider=provider.name(),
                latency_ms=round((time.perf_counter() - started) * 1000, 1)
            );
        }
        self.tally.unrecovered += 1;
        return self.fallback.draft(prompt, max_tokens=max_tokens);
    }

    def close {
        for p in self.providers {
            p.close();
        }
    }
}
