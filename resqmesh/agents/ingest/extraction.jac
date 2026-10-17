"""Raw signal -> typed IncidentReport.

This is the single place A1 lets a language model touch the data, and the model's
job here is extraction only: pull structure out of free text. It never produces a
number that reaches a decision — severities and headcounts it extracts are
*claims made by the reporter*, which A3 weighs, not measurements.

Failure is designed to be quiet and lossless. If the provider errors or returns
something that does not validate, the signal still becomes a report: hazard
`UNKNOWN`, extraction confidence zero, and the gazetteer still gets a try at the
raw text. Evidence is never dropped, and the capability that degrades is
extraction quality, not the capacity to decide.
"""

import math;
import from resqmesh.agents.ingest.redact { redact }
import from resqmesh.contracts.enums { HazardType, LocationSource, VulnerabilityFlag }
import from resqmesh.contracts.models { IncidentReport, RawSignal }
import from resqmesh.contracts.ports { GeocodePort, GeocodeResult, LLMPort }

"""The functional-need whitelist, as members and as wire values."""
glob WHITELIST: list[VulnerabilityFlag] = [f for f in VulnerabilityFlag];
glob WHITELIST_VALUES: list[str] = [f.value for f in VulnerabilityFlag];

"""A model payload that does not fit its response schema.

Raised with a single argument: the list of invalid fields, one `"field: reason"`
entry each, so the trace can say how much of the extraction was unusable.
"""
class SchemaValidationError(ValueError) {}

"""How many fields a schema failure rejected."""
def schema_error_count(exc: SchemaValidationError) -> int {
    if exc.args and isinstance(exc.args[0], (list, tuple)) {
        return len(exc.args[0]);
    }
    return 1;
}

"""One field's value failed validation. Internal to the schema validators."""
class InvalidField(ValueError) {}

# ------------------------------------------------------------------ field validators
# Lenient about representation (a numeric string, an integral float) and strict about
# meaning: a value that does not fit is an error, never clamped into something valid.

def lax_int(value: any) -> int {
    if isinstance(value, bool) {
        return int(value);
    }
    if isinstance(value, int) {
        return value;
    }
    if isinstance(value, float) {
        if math.isfinite(value) and value.is_integer() {
            return int(value);
        }
        raise InvalidField("int_from_float");
    }
    if isinstance(value, str) {
        text = value.strip();
        try {
            return int(text);
        } except ValueError {
            try {
                as_float = float(text);
            } except ValueError {
                raise InvalidField("int_parsing");
            }
            if math.isfinite(as_float) and as_float.is_integer() {
                return int(as_float);
            }
            raise InvalidField("int_parsing");
        }
    }
    raise InvalidField("int_type");
}

def lax_float(value: any) -> float {
    if isinstance(value, (bool, int, float)) {
        return float(value);
    }
    if isinstance(value, str) {
        try {
            return float(value.strip());
        } except ValueError {
            raise InvalidField("float_parsing");
        }
    }
    raise InvalidField("float_type");
}

def strict_str(value: any, strip_whitespace: bool) -> str {
    if not isinstance(value, str) {
        raise InvalidField("string_type");
    }
    return value.strip() if strip_whitespace else value;
}

def bounded(value: float, lo: float | None, hi: float | None) -> None {
    if lo is not None and not (value >= lo) {
        raise InvalidField("greater_than_equal");
    }
    if hi is not None and not (value <= hi) {
        raise InvalidField("less_than_equal");
    }
}

def hazard_value(value: any) -> HazardType {
    if isinstance(value, HazardType) {
        return value;
    }
    try {
        return HazardType(value);
    } except ValueError {
        raise InvalidField("enum");
    }
}

"""Drop anything outside the functional-need whitelist.

Proposal section 10.4: ethnicity, religion, language and any proxy for them never
enter triage. A model that volunteers one is not an error worth losing the report
over — the value is simply discarded here, before it can reach A3.
"""
def functional_need_only(value: any) -> list[VulnerabilityFlag] {
    if value is None {
        return [];
    }
    values = list(value) if isinstance(value, (list, tuple, set, frozenset)) else [value];
    return [VulnerabilityFlag(x) for x in values if x in WHITELIST or x in WHITELIST_VALUES];
}

"""The response schema A1 asks the model to fill.

Unknown keys are ignored (models pad their output), but every known key is
validated strictly: a malformed value fails the whole extraction rather than being
coerced into something that looks valid. Strings are stripped of surrounding
whitespace.
"""
obj ExtractedReport {
    has hazard_type: HazardType = HazardType.UNKNOWN,
        description: str = "",
        raw_place_text: str = "",
        severity_claim: int | None = None,
        reported_people_affected: int | None = None,
        vulnerability_flags: list[VulnerabilityFlag] = [],
        extraction_confidence: float = 0.5;

    """Validate a model payload. Raises SchemaValidationError naming every bad field."""
    static def from_payload(payload: any) -> ExtractedReport {
        if not isinstance(payload, dict) {
            raise SchemaValidationError(["payload: model_type"]);
        }
        errors: list[str] = [];
        fields: dict[str, any] = {};
        for (key, raw) in payload.items() {
            try {
                if key == "hazard_type" {
                    fields[key] = hazard_value(raw);
                } elif key == "description" or key == "raw_place_text" {
                    fields[key] = strict_str(raw, True);
                } elif key == "severity_claim" {
                    if raw is None {
                        fields[key] = None;
                    } else {
                        sev = lax_int(raw);
                        bounded(sev, 0, 4);
                        fields[key] = sev;
                    }
                } elif key == "reported_people_affected" {
                    if raw is None {
                        fields[key] = None;
                    } else {
                        people = lax_int(raw);
                        bounded(people, 0, None);
                        fields[key] = people;
                    }
                } elif key == "vulnerability_flags" {
                    fields[key] = functional_need_only(raw);
                } elif key == "extraction_confidence" {
                    conf = lax_float(raw);
                    bounded(conf, 0.0, 1.0);
                    fields[key] = conf;
                }
            } except InvalidField as exc {
                errors.append(f"{key}: {exc}");
            }
        }
        if errors {
            raise SchemaValidationError(errors);
        }
        return ExtractedReport(**fields);
    }
}

"""The response schema for reading a damage photograph.

Deliberately *not* `DamageObservation`: that contract carries a `report_id` the
model cannot know. The caller attaches it when building the observation from this
reading.
"""
obj VisionReading {
    has severity_0_4: int,
        tags: list[str] = [],
        model_confidence: float = 0.5;

    """Validate a model payload. Raises SchemaValidationError naming every bad field."""
    static def from_payload(payload: any) -> VisionReading {
        if not isinstance(payload, dict) {
            raise SchemaValidationError(["payload: model_type"]);
        }
        errors: list[str] = [];
        fields: dict[str, any] = {};
        if "severity_0_4" not in payload {
            errors.append("severity_0_4: missing");
        }
        for (key, raw) in payload.items() {
            try {
                if key == "severity_0_4" {
                    sev = lax_int(raw);
                    bounded(sev, 0, 4);
                    fields[key] = sev;
                } elif key == "tags" {
                    if not isinstance(raw, (list, tuple, set, frozenset)) {
                        raise InvalidField("tuple_type");
                    }
                    tags: list[str] = [];
                    for (i, tag) in enumerate(list(raw)) {
                        if isinstance(tag, str) {
                            tags.append(tag);
                        } else {
                            errors.append(f"tags.{i}: string_type");
                        }
                    }
                    fields[key] = tags;
                } elif key == "model_confidence" {
                    conf = lax_float(raw);
                    bounded(conf, 0.0, 1.0);
                    fields[key] = conf;
                }
            } except InvalidField as exc {
                errors.append(f"{key}: {exc}");
            }
        }
        if errors {
            raise SchemaValidationError(errors);
        }
        return VisionReading(**fields);
    }
}

"""Deterministic, so re-ingesting a signal can never create a second report."""
def report_id_for(signal: RawSignal) -> str {
    return f"R-{signal.signal_id}";
}

"""A fix looser than this is not trusted over a named place. 200 m is about the
worst a phone GPS does with a view of the sky, and about a city block: tight enough
to pick the right division, loose enough to accept an indoor fix."""
glob USABLE_ACCURACY_M: float = 200.0;

"""Coordinates first, then the extracted place, then the whole message.

Coordinates win because they are the only input that says where the *emergency*
is. A resolved place name yields the division's centroid, which can sit a couple of
kilometres from the person who called — fine for a map at division granularity, not
somewhere to drive a crew.

A coordinate that lands outside every division is not retried against the text:
the reporter told us precisely where they are, and if that is not a place this
system covers, guessing from a name they also typed would be inventing coverage we
do not have. It is held.

The fallback to the raw body matters most when extraction has failed: a report the
model could not parse can still be placed from the text it arrived in.
"""
def locate(
    gazetteer: GeocodePort, place_text: str, body: str, signal: RawSignal
) -> tuple[GeocodeResult, LocationSource] {
    precise = signal.accuracy_m is None or signal.accuracy_m <= USABLE_ACCURACY_M;
    if signal.lat is not None and signal.lon is not None and precise {
        return (gazetteer.locate(signal.lat, signal.lon), signal.location_source);
    }
    if place_text {
        hit = gazetteer.resolve(place_text);
        if hit.matched {
            return (hit, LocationSource.PLACE_TEXT);
        }
    }
    return (gazetteer.resolve(body), LocationSource.PLACE_TEXT);
}

"""Build one report from one signal. Returns `(report, failure_reason)`.

`failure_reason` is None on a clean extraction; otherwise it names what degraded,
for the trace.
"""
def extract_report(
    signal: RawSignal, llm: LLMPort, gazetteer: GeocodePort, context: str = ""
) -> tuple[IncidentReport, str | None] {
    safe_body = redact(signal.body);
    failure: str | None = None;
    fields: ExtractedReport;
    try {
        result = llm.extract(safe_body, ExtractedReport, lang_hint=signal.lang_hint, context=context);
        fields = ExtractedReport.from_payload(result.payload);
    } except SchemaValidationError as exc {
        failure = f"schema: {schema_error_count(exc)} invalid field(s)";
        fields = ExtractedReport(description=safe_body[:500].strip(), extraction_confidence=0.0);
    } except Exception as exc {
        # provider outage, timeout, circuit open
        failure = f"provider: {type(exc).__name__}";
        fields = ExtractedReport(description=safe_body[:500].strip(), extraction_confidence=0.0);
    }

    located = locate(gazetteer, fields.raw_place_text, safe_body, signal);
    where: GeocodeResult = located[0];
    source: LocationSource = located[1];
    built = IncidentReport(
        report_id=report_id_for(signal),
        signal_id=signal.signal_id,
        source_id=signal.source_id,
        hazard_type=fields.hazard_type,
        description=fields.description or safe_body[:500],
        raw_place_text=fields.raw_place_text or (where.gn_name or ""),
        resolved_gn_id=where.gn_id if where.matched else None,
        lat=where.lat if where.matched else None,
        lon=where.lon if where.matched else None,
        location_source=source if where.matched else LocationSource.NONE,
        location_accuracy_m=signal.accuracy_m if source != LocationSource.PLACE_TEXT else None,
        severity_claim=fields.severity_claim,
        reported_people_affected=fields.reported_people_affected,
        vulnerability_flags=list(fields.vulnerability_flags),
        observed_at=signal.received_at,
        extraction_confidence=fields.extraction_confidence
    );
    return (built, failure);
}
