"""The provider router, against a faked network.

Every provider is an `httpx.MockTransport` scripted to succeed, rate-limit, time out
or return garbage, so each failure-handling promise in proposal section 4.3 is
asserted without a real API key or a single real request.
"""

import json;
import logging;
import os;
import tempfile;
import httpx;
import from datetime { datetime, UTC }
import from resqmesh.adapters.fakes { FakeGazetteer }
import from resqmesh.adapters.llm.prompts { EXTRACTION_SYSTEM, VISION_SYSTEM, VISION_FIELDS }
import from resqmesh.adapters.llm.config { plan_chain, router_from_env }
import from resqmesh.adapters.llm.openai_compat { ChatProvider, ProviderError, ProviderSpec }
import from resqmesh.adapters.llm.router { ProviderRouter, RouterConfig, log as router_log }
import from resqmesh.adapters.llm.rules { ProviderUnavailable, RuleBasedExtractor }
import from resqmesh.agents.ingest.extraction { ExtractedReport, VisionReading, extract_report }
import from resqmesh.contracts.enums { HazardType, LLMProvider, SourceChannel, VulnerabilityFlag }
import from resqmesh.contracts.models { RawSignal }
import from resqmesh.contracts.ports { LLMPort }

glob GOOD: dict[str, any] = {
    "hazard_type": "flood",
    "description": "Flooding reported.",
    "raw_place_text": "Kolonnawa",
    "severity_claim": 3,
    "reported_people_affected": 12,
    "vulnerability_flags": ["elderly"],
    "extraction_confidence": 0.9
};

# Exactly what the vision prompt asks for; no report_id, which the model cannot know.
glob VISION_OK: dict[str, any] = {"severity_0_4": 3, "tags": ["flood"], "model_confidence": 0.8};

def completion(payload: any) -> httpx.Response {
    content = payload if isinstance(payload, str) else json.dumps(payload);
    return httpx.Response(200, json={"choices": [{"message": {"content": content}}]});
}

def with_field(key: str, value: any) -> dict[str, any] {
    return {**GOOD, key: value};
}

"""A provider endpoint that plays back responses in order and records requests.
The last response repeats once the others are used up."""
obj Script {
    has responses: list[any],
        requests: list[dict[str, any]] = [],
        headers: list[any] = [];

    def postinit {
        self.requests = [];
        self.headers = [];
    }

    def __call__(request: httpx.Request) -> httpx.Response {
        self.requests.append(json.loads(request.content));
        self.headers.append(request.headers);
        nxt: any = self.responses.pop(0) if len(self.responses) > 1 else self.responses[0];
        if isinstance(nxt, Exception) {
            raise nxt;
        }
        return nxt() if callable(nxt) else nxt;
    }
}

def provider(name: LLMProvider, script: Script, vision: bool = False) -> ChatProvider {
    spec = ProviderSpec(
        name=name,
        base_url=f"https://{name.value}.test/v1",
        model=f"{name.value}-model",
        api_key="key-123",
        vision_model=f"{name.value}-vision" if vision else None
    );
    return ChatProvider(spec=spec, transport=httpx.MockTransport(script));
}

obj Clock {
    has t: float = 1000.0;

    def __call__ -> float {
        return self.t;
    }
}

def make_router(
    providers: list[ChatProvider], clock: Clock | None = None, **cfg: any
) -> tuple[ProviderRouter, list[float]] {
    slept: list[float] = [];
    r = ProviderRouter(
        providers=providers, config=RouterConfig(**cfg), sleep=slept.append, clock=clock or Clock()
    );
    return (r, slept);
}

"""Collects every record the router logs, for the privacy test."""
class Capture(logging.Handler) {
    def init(self: Capture) {
        super.init(logging.DEBUG);
        self.records: list[logging.LogRecord] = [];
    }

    override def emit(self: Capture, record: logging.LogRecord) {
        self.records.append(record);
    }
}

def photo -> str {
    path = os.path.join(tempfile.mkdtemp(), "damage.jpg");
    with open(path, "wb") as fh {
        fh.write(b"\xff\xd8\xff fake jpeg");
    }
    return path;
}

# --------------------------------------------------------------------------- #
# The happy path and the request itself
# --------------------------------------------------------------------------- #

test "first healthy provider answers" {
    r = make_router([provider(LLMProvider.GEMINI, Script(responses=[completion(GOOD)]))])[0];
    result = r.extract("Flooding in Kolonnawa", ExtractedReport);
    assert result.provider is LLMProvider.GEMINI;
    assert result.payload["raw_place_text"] == "Kolonnawa";
    assert not result.repaired;
}

test "router is an llm port" {
    assert isinstance(ProviderRouter(providers=[]), LLMPort);
}

test "request is deterministic json and authenticated" {
    script = Script(responses=[completion(GOOD)]);
    make_router([provider(LLMProvider.GEMINI, script)])[0].extract("x", ExtractedReport, lang_hint="si");
    body = script.requests[0];
    assert body["model"] == "gemini-model";
    assert body["temperature"] == 0;
    assert body["response_format"] == {"type": "json_object"};
    assert body["messages"][0]["content"] == EXTRACTION_SYSTEM;
    assert "language hint: si" in body["messages"][1]["content"];
    assert script.headers[0]["authorization"] == "Bearer key-123";
}

# --------------------------------------------------------------------------- #
# Retry, failover, circuit breaker
# --------------------------------------------------------------------------- #

test "rate limit is retried with exponential backoff" {
    script = Script(responses=[httpx.Response(429), httpx.Response(429), completion(GOOD)]);
    (r, slept) = make_router([provider(LLMProvider.GEMINI, script)], max_retries=2, backoff_base_s=0.5);
    assert r.extract("x", ExtractedReport).provider is LLMProvider.GEMINI;
    assert slept == [0.5, 1.0];
}

test "persistent rate limit fails over" {
    gemini = Script(responses=[httpx.Response(429)]);
    r = make_router(
        [provider(LLMProvider.GEMINI, gemini), provider(LLMProvider.GROQ, Script(responses=[completion(GOOD)]))],
        max_retries=2
    )[0];
    assert r.extract("x", ExtractedReport).provider is LLMProvider.GROQ;
    assert len(gemini.requests) == 3;  # first attempt + 2 retries, then move on
}

test "non retryable errors fail over immediately" {
    # A bad key fails identically on every retry: don't waste the time budget.
    for status in [400, 401, 403, 404] {
        gemini = Script(responses=[httpx.Response(status)]);
        (r, slept) = make_router(
            [provider(LLMProvider.GEMINI, gemini), provider(LLMProvider.GROQ, Script(responses=[completion(GOOD)]))]
        );
        assert r.extract("x", ExtractedReport).provider is LLMProvider.GROQ, status;
        assert len(gemini.requests) == 1 and slept == [], status;
    }
}

test "network errors are retryable" {
    script = Script(responses=[httpx.ConnectError("no route"), completion(GOOD)]);
    (r, slept) = make_router([provider(LLMProvider.GEMINI, script)]);
    assert r.extract("x", ExtractedReport).provider is LLMProvider.GEMINI;
    assert len(slept) == 1;
}

test "circuit opens skips then probes after cooldown" {
    clock = Clock();
    gemini = Script(responses=[httpx.Response(401)]);
    groq = Script(responses=[completion(GOOD)]);
    r = make_router(
        [provider(LLMProvider.GEMINI, gemini), provider(LLMProvider.GROQ, groq)],
        clock=clock, breaker_threshold=2, breaker_cooldown_s=60
    )[0];

    for _ in range(2) {
        r.extract("x", ExtractedReport);
    }
    assert [h.open for h in r.health()] == [True, False];

    r.extract("x", ExtractedReport);
    assert len(gemini.requests) == 2;  # open: not called at all

    clock.t += 61;  # half-open: one probe goes through
    gemini.responses = [completion(GOOD)];
    assert r.extract("x", ExtractedReport).provider is LLMProvider.GEMINI;
    assert [h.open for h in r.health()] == [False, False];
}

# --------------------------------------------------------------------------- #
# Schema repair: one attempt, then escalate; never coerce
# --------------------------------------------------------------------------- #

test "invalid reply gets one repair on the same provider" {
    script = Script(responses=[completion(with_field("severity_claim", 9)), completion(GOOD)]);
    r = make_router([provider(LLMProvider.GEMINI, script)])[0];
    result = r.extract("x", ExtractedReport);
    assert result.provider is LLMProvider.GEMINI and result.repaired;
    repair_msg = script.requests[1]["messages"][-1]["content"];
    assert "severity_claim" in repair_msg;  # the model is told exactly what failed
}

test "unparseable reply is repaired too" {
    script = Script(responses=[completion("Sure! Here is the JSON: {oops"), completion(GOOD)]);
    assert make_router([provider(LLMProvider.GEMINI, script)])[0].extract("x", ExtractedReport).repaired;
}

test "still invalid after repair escalates to the next provider" {
    bad = Script(responses=[completion(with_field("hazard_type", "tsunami"))]);
    r = make_router(
        [provider(LLMProvider.GEMINI, bad), provider(LLMProvider.GROQ, Script(responses=[completion(GOOD)]))]
    )[0];
    result = r.extract("x", ExtractedReport);
    assert result.provider is LLMProvider.GROQ;
    assert len(bad.requests) == 2;  # first reply + exactly one repair
}

# --------------------------------------------------------------------------- #
# Degraded mode: never silence
# --------------------------------------------------------------------------- #

test "every provider down falls back to offline rules" {
    r = make_router(
        [
            provider(LLMProvider.GEMINI, Script(responses=[httpx.Response(503)])),
            provider(LLMProvider.GROQ, Script(responses=[httpx.ConnectError("offline")]))
        ],
        max_retries=0
    )[0];
    result = r.extract("Flooding in Kolonnawa, 12 people trapped", ExtractedReport);
    assert result.provider is LLMProvider.RULES;
    assert result.payload["hazard_type"] is HazardType.FLOOD;
    assert result.payload["reported_people_affected"] == 12;
    assert result.payload["extraction_confidence"] < 0.5;  # honest about being degraded
    assert r.tally.requests == 1 and r.tally.unrecovered == 1;
}

test "no providers at all is still usable" {
    result = ProviderRouter(providers=[]).extract("Flooding in Kolonnawa", ExtractedReport);
    assert result.provider is LLMProvider.RULES;
}

test "offline extraction still yields a located report" {
    # The degraded-mode promise, through A1: offline, a report still becomes a typed,
    # located incident, so triage and routing keep producing decisions.
    signal = RawSignal(
        signal_id="S1", channel=SourceChannel.SMS, source_id="s",
        body="Flooding in Kolonnawa, 12 people trapped", received_at=datetime.now(UTC)
    );
    (built, failure) = extract_report(signal, ProviderRouter(providers=[]), FakeGazetteer());
    assert failure is None and built.is_located() and built.resolved_gn_id == "KLN-003";
}

test "offline rules read sinhala and tamil hazard words" {
    cases = [
        ("ගංවතුර", HazardType.FLOOD), ("வெள்ளம்", HazardType.FLOOD),
        ("නායයෑම", HazardType.LANDSLIDE), ("மண்சரிவு", HazardType.LANDSLIDE)
    ];
    for (text, expected) in cases {
        assert RuleBasedExtractor().extract(text, ExtractedReport).payload["hazard_type"] is expected, text;
    }
}

test "draft degrades to empty text not an error" {
    r = make_router([provider(LLMProvider.GEMINI, Script(responses=[httpx.Response(503)]))], max_retries=0)[0];
    result = r.draft("summarise");
    assert result.provider is LLMProvider.RULES and result.payload["text"] == "";
}

# --------------------------------------------------------------------------- #
# Vision
# --------------------------------------------------------------------------- #

test "vision skips text only providers" {
    groq = Script(responses=[completion(VISION_OK)]);
    gemini = Script(responses=[completion(VISION_OK)]);
    r = make_router([provider(LLMProvider.GROQ, groq), provider(LLMProvider.GEMINI, gemini, vision=True)])[0];
    assert r.vision(photo(), VisionReading).provider is LLMProvider.GEMINI;
    assert groq.requests == [];
    image = gemini.requests[0]["messages"][1]["content"][1]["image_url"]["url"];
    assert image.startswith("data:image/jpeg;base64,");
    assert gemini.requests[0]["model"] == "gemini-vision";
}

test "vision refuses rather than inventing a severity" {
    r = make_router([provider(LLMProvider.GROQ, Script(responses=[completion(VISION_OK)]))])[0];
    with testraises(ProviderUnavailable) {
        r.vision(photo(), VisionReading);
    }
}

# --------------------------------------------------------------------------- #
# Privacy and prompt integrity
# --------------------------------------------------------------------------- #

test "report text never reaches the logs" {
    secret = "Kolonnawa report with a distinctive phrase zebra-quartz";
    r = make_router(
        [
            provider(LLMProvider.GEMINI, Script(responses=[completion(with_field("severity_claim", 9))])),
            provider(LLMProvider.GROQ, Script(responses=[httpx.Response(503)]))
        ],
        max_retries=1
    )[0];
    capture = Capture();
    previous = router_log.level;
    router_log.addHandler(capture);
    router_log.setLevel(logging.DEBUG);
    try {
        r.extract(secret, ExtractedReport);
    } finally {
        router_log.removeHandler(capture);
        router_log.setLevel(previous);
    }
    text = "\n".join([rec.getMessage() for rec in capture.records]);
    assert capture.records;  # failures were logged...
    assert "zebra-quartz" not in text;  # ...without the content
}

test "prompt offers exactly the contract values" {
    # The prompt is generated from the enums, so it cannot drift from the schema.
    for member in [*HazardType, *VulnerabilityFlag] {
        assert f'"{member.value}"' in EXTRACTION_SYSTEM, member;
    }
}

test "prompt forbids inferring vulnerability from identity" {
    assert "Never infer from names, language, religion or ethnicity" in EXTRACTION_SYSTEM;
}

# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #

test "default chain is gemini groq deepseek without ollama" {
    plan = plan_chain({"GEMINI_API_KEY": "g", "GROQ_API_KEY": "q", "DEEPSEEK_API_KEY": "d"})[1];
    assert plan.active == [LLMProvider.GEMINI, LLMProvider.GROQ, LLMProvider.DEEPSEEK];
}

test "providers without keys are skipped not fatal" {
    plan = plan_chain({"GEMINI_API_KEY": "g"})[1];
    assert plan.active == [LLMProvider.GEMINI];
    assert dict(plan.skipped) == {"groq": "GROQ_API_KEY not set", "deepseek": "DEEPSEEK_API_KEY not set"};
}

test "order is configurable" {
    plan = plan_chain({"RESQMESH_LLM_ORDER": "deepseek,gemini", "GEMINI_API_KEY": "g", "DEEPSEEK_API_KEY": "d"})[1];
    assert plan.active == [LLMProvider.DEEPSEEK, LLMProvider.GEMINI];
}

test "ollama is opt in and needs no key" {
    (specs, plan) = plan_chain({"RESQMESH_LLM_ORDER": "ollama"});
    assert plan.active == [LLMProvider.OLLAMA];
    assert specs[0].base_url == "http://localhost:11434/v1" and not specs[0].supports_vision();
}

test "offline flag skips every hosted provider" {
    (built, plan) = router_from_env({"RESQMESH_OFFLINE": "1", "GEMINI_API_KEY": "g"});
    assert plan.active == [] and built.providers == [];
}

test "unknown provider names are reported" {
    plan = plan_chain({"RESQMESH_LLM_ORDER": "gemini,openai", "GEMINI_API_KEY": "g"})[1];
    assert ("openai", "unknown provider") in plan.skipped;
}

test "gemini reads photos groq does not" {
    specs = plan_chain({"GEMINI_API_KEY": "g", "GROQ_API_KEY": "q"})[0];
    assert [s.supports_vision() for s in specs] == [True, False];
}

test "empty completion is retryable" {
    # Some providers return an empty message under load; treat as transient.
    raised: ProviderError | None = None;
    try {
        provider(LLMProvider.GEMINI, Script(responses=[completion("  ")])).complete([], json_mode=True);
    } except ProviderError as exc {
        raised = exc;
    }
    assert raised is not None and raised.retryable;
}

test "vision prompt fields match the reading schema" {
    # Every field the prompt asks for must validate: a mismatch here means every real
    # photo reply fails validation and every photo goes unread.
    assert VisionReading.from_payload(VISION_OK);
    reading_fields = list(vars(VisionReading(severity_0_4=0)).keys());
    assert sorted(reading_fields) == sorted(VISION_FIELDS);
    for name in reading_fields {
        assert f'"{name}"' in VISION_SYSTEM, name;
    }
}

test "provider error carries the providers explanation" {
    # A retired model and a wrong URL must not look like the same opaque 404.
    bodies: list[any] = [
        # Google's list shape
        [{"error": {"code": 404, "message": "This model models/x is no longer available", "status": "NOT_FOUND"}}],
        # OpenAI's shape
        {"error": {"message": "This model models/x is no longer available", "code": "model_not_found"}}
    ];
    for body in bodies {
        raised: ProviderError | None = None;
        try {
            provider(LLMProvider.GEMINI, Script(responses=[httpx.Response(404, json=body)])).complete(
                [], json_mode=True
            );
        } except ProviderError as exc {
            raised = exc;
        }
        assert raised is not None;
        assert "no longer available" in str(raised) and raised.status == 404;
    }
}

test "provider error never contains the key" {
    echoed = {"error": {"message": "invalid key key-123 for project"}};
    raised: ProviderError | None = None;
    try {
        provider(LLMProvider.GEMINI, Script(responses=[httpx.Response(401, json=echoed)])).complete(
            [], json_mode=True
        );
    } except ProviderError as exc {
        raised = exc;
    }
    assert raised is not None;
    assert "key-123" not in str(raised) and "<key>" in str(raised);
}
