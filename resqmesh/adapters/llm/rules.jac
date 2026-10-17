"""Deterministic offline extraction: the last tier of the provider chain.

When every hosted provider is unreachable this extractor takes over. It needs no
network, no model and no compute to speak of, and it is deterministic. It classifies
the hazard from keywords, lifts a stated headcount and a few vulnerability cues, and
leaves place resolution to A1's gazetteer, which already falls back to scanning the
raw text. The capability that degrades is the quality of free-text extraction, not
the capacity to decide. Its lower `extraction_confidence` is honest: A3 and the
SITREP both see it.

The Sinhala and Tamil keywords are a starting set and need review by a native speaker.
"""

import re;
import from resqmesh.contracts.enums { HazardType, LLMProvider }
import from resqmesh.contracts.ports { ExtractionResult, LLMPort }

"""No tier can serve this kind of call (e.g. reading a photo offline)."""
class ProviderUnavailable(RuntimeError) {}

"""Keyword sets per hazard, checked in this order; the first match wins."""
glob HAZARD_KEYWORDS: list[tuple[HazardType, list[str]]] = [
    (HazardType.FLOOD, ["flood", "water", "inundat", "rising", "submerg", "ගංවතුර", "ජලය", "வெள்ளம்", "நீர்"]),
    (HazardType.LANDSLIDE, ["landslide", "slip", "slope", "earth slip", "mudslide", "නායයෑම", "නාය", "மண்சரிவு"]),
    (HazardType.ROAD_BLOCKED, ["road", "culvert", "bridge", "impassable", "blocked"]),
    (HazardType.STRUCTURAL_DAMAGE, ["collapse", "damaged", "roof", "wall"]),
    (HazardType.MEDICAL, ["injur", "medical", "dialysis", "hospital", "ambulance", "රෝහල", "மருத்துவ"])
];

"""Phrases that deny a hazard, expressed as severity 0 so A1 can model the
contradiction instead of averaging it away."""
glob ALL_CLEAR: list[str] = [
    "passable", "receded", "all clear", "false alarm", "no flooding", "is clear", "now open"
];

glob VULNERABILITY_CUES: list[tuple[str, list[str]]] = [
    ("medical_dependency", ["dialysis", "oxygen", "insulin", "bedridden", "pregnant"]),
    ("mobility_limited", ["wheelchair", "cannot walk", "disabled", "immobile"]),
    ("elderly", ["elderly", "old people", "aged", "grandmother", "grandfather"]),
    ("children_present", ["child", "children", "baby", "infant", "kids"])
];

glob PEOPLE_RE: any = re.compile(r"\b(\d{1,4})\s*(?:people|persons|trapped|stranded|families)");

"""An LLMPort with no model behind it."""
obj RuleBasedExtractor(LLMPort) {
    has provider: LLMProvider = LLMProvider.RULES,
        confidence: float = 0.35;

    def classify(text: str) -> HazardType {
        low = text.lower();
        for (hazard, keywords) in HAZARD_KEYWORDS {
            if any([k in low for k in keywords]) {
                return hazard;
            }
        }
        return HazardType.UNKNOWN;
    }

    """First capitalised word; the gazetteer also scans the whole text."""
    static def guess_place(text: str) -> str {
        tokens = re.findall(r"\b[A-Z][a-z]{3,}\b", text);
        return tokens[0] if tokens else "";
    }

    override def extract(text: str, schema: type, lang_hint: str = "unknown") -> ExtractionResult {
        low = text.lower();
        people = PEOPLE_RE.search(low);
        all_clear = any([p in low for p in ALL_CLEAR]);
        severity = 0 if all_clear else min(4, 1 + low.count("urgent") + low.count("critical"));
        payload: dict[str, any] = {
            "hazard_type": self.classify(text),
            "description": text.strip()[:500],
            "raw_place_text": RuleBasedExtractor.guess_place(text),
            "severity_claim": severity,
            "reported_people_affected": int(people.group(1)) if people else None,
            "vulnerability_flags": [f for (f, words) in VULNERABILITY_CUES if any([w in low for w in words])],
            "extraction_confidence": self.confidence
        };
        return ExtractionResult(payload=payload, provider=self.provider, latency_ms=0.0);
    }

    """There is no honest way to read a photograph without a model. Raising rather
    than guessing: an invented severity could move a crew."""
    override def vision(image_path: str, schema: type) -> ExtractionResult {
        raise ProviderUnavailable("no vision-capable provider reachable; photo left unread");
    }

    """No narrative offline. A6 builds its SITREP from templates, not drafts."""
    override def draft(prompt: str, max_tokens: int = 512) -> ExtractionResult {
        return ExtractionResult(payload={"text": ""}, provider=self.provider, latency_ms=0.0);
    }
}
