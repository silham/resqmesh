"""Every prompt the system sends, versioned. This file is the prompt inventory.

Two rules shape all of them:

* **The model extracts; it never computes.** Prompts ask for what the reporter
  *said* (a claimed headcount, a claimed severity), never for a distance, a
  score or a decision. Numbers that reach a decision come from deterministic
  code (proposal section 3.1).
* **Allowed values come from the contracts.** The enum lists below are generated
  from `resqmesh.contracts.enums`, so the prompt cannot offer the model a
  value the schema would reject, or omit one it would accept.

Bump the version string whenever wording changes; it is recorded with results so a
replay can tell which prompt produced which extraction.
"""

import from resqmesh.contracts.enums { HazardType, VulnerabilityFlag }

glob EXTRACTION_PROMPT_VERSION: str = "extract-v1";
glob VISION_PROMPT_VERSION: str = "vision-v1";
glob REPAIR_PROMPT_VERSION: str = "repair-v1";

"""Every member of an enum, quoted and comma-separated, in declaration order."""
def enum_values(members: any) -> str {
    return ", ".join([f'"{m.value}"' for m in members]);
}

glob EXTRACTION_SYSTEM: str = (
    "You read disaster field reports from Sri Lanka and extract structured facts.\n"
    "Reports may be in Sinhala, Tamil, English, or a mix. Reply with ONE JSON object only.\n"
    "\n"
    "Fields:\n"
    f"- \"hazard_type\": one of {enum_values(HazardType)}. Use \"unknown\" if unclear.\n"
    "- \"description\": one short English sentence restating what the reporter said. Add nothing.\n"
    "- \"raw_place_text\": the place name exactly as the reporter gave it, romanised in its usual\n"
    "  English spelling (e.g. \"Kolonnawa\"). Empty string if no place is named.\n"
    "  NEVER guess or invent a place. A wrong location is worse than none.\n"
    "- \"severity_claim\": integer 0-4, the reporter's own description of how bad it is:\n"
    "  0 = the reporter says the hazard is gone or not present (\"receded\", \"road passable\", \"false alarm\");\n"
    "  1 = minor; 2 = moderate; 3 = severe; 4 = life-threatening right now.\n"
    "  null if the report gives no indication.\n"
    "- \"reported_people_affected\": integer only if the reporter states a number, else null. Never estimate.\n"
    f"- \"vulnerability_flags\": list, only from {enum_values(VulnerabilityFlag)}, and only when the\n"
    "  report explicitly mentions it. Never infer from names, language, religion or ethnicity.\n"
    "- \"extraction_confidence\": 0.0-1.0, how clearly the report supports your extraction.\n"
);

"""The fields the vision prompt asks for. They are exactly the fields of A1's
`VisionReading`, so every well-formed reply validates."""
glob VISION_FIELDS: list[str] = ["severity_0_4", "tags", "model_confidence"];

glob VISION_SYSTEM: str = (
    "You assess a photograph sent by a disaster field responder. Reply with ONE JSON object only.\n"
    "\n"
    "Fields:\n"
    f"- \"{VISION_FIELDS[0]}\": integer:\n"
    "  0 = no visible damage or water;\n"
    "  1 = minor: shallow water, debris, passable;\n"
    "  2 = moderate: water inside buildings, road partly blocked;\n"
    "  3 = severe: structural collapse, road destroyed, people on roofs;\n"
    "  4 = critical: immediate threat to life visible.\n"
    f"- \"{VISION_FIELDS[1]}\": short lowercase labels for what is visible, e.g. [\"flood\", \"collapsed_structure\", \"people_trapped\"].\n"
    f"- \"{VISION_FIELDS[2]}\": 0.0-1.0.\n"
    "Describe only what is visible. Do not identify people.\n"
);

glob REPAIR_TEMPLATE: str = (
    "Your previous reply was not valid for the required schema: {error}\n"
    "Reply again with ONE corrected JSON object only. Do not add commentary."
);

"""The user turn for an extraction: the report fenced off from the instructions."""
def extraction_user(text: str, lang_hint: str) -> str {
    hint = "" if lang_hint in ("", "unknown") else f" (language hint: {lang_hint})";
    return f"Field report{hint}:\n<<<\n{text}\n>>>";
}
