"""Pseudonymisation before anything leaves the machine.

Proposal section 10.3: personal identifiers are stripped from text before it is
sent to any hosted language model, and reporter telephone numbers are stored only
as salted hashes — the raw identifier is never persisted.

Both functions are deterministic, so the same reporter always maps to the same
pseudonym within a deployment. That is what lets per-source trust accumulate
without the system ever holding the real number.
"""

import hashlib;
import hmac;
import re;

# Sri Lankan mobiles (07x xxx xxxx, +94 7x ...) and landlines, with the usual
# separators. Broad on purpose: a false positive costs a few digits of context, a
# false negative leaks a phone number to a third-party API.
glob PHONE_RE: any = re.compile(r"(?:\+?94[\s-]?|0)(?:\d[\s-]?){8,9}\d");

glob EMAIL_RE: any = re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+");

# NIC: old format 9 digits + V/X, new format 12 digits.
glob NIC_RE: any = re.compile(r"\b(?:\d{9}[VvXx]|\d{12})\b");

# A decimal coordinate pair, e.g. "6.9497, 79.9853" or "6.9497 79.9853". Sri Lanka
# is 5-10 N, 79-82 E, so the ranges are narrow enough not to eat ordinary numbers.
# Structured coordinates travel in their own fields and never through here; this
# catches the reporter who types their location into the message, whose precise
# position would otherwise be handed to a third-party model with the text.
glob LATLON_RE: any = re.compile(r"\b([5-9]|10)\.\d{3,}\s*[,;]?\s*(?:7[9]|8[0-2])\.\d{3,}\b");

"""Replace phone numbers, emails, NIC numbers and coordinates with placeholders."""
def redact(text: str) -> str {
    text = EMAIL_RE.sub("[email]", text);
    text = NIC_RE.sub("[nic]", text);
    text = LATLON_RE.sub("[coords]", text);
    return PHONE_RE.sub("[phone]", text);
}

"""Salted, keyed hash of a reporter identifier.

HMAC rather than a bare hash so the pseudonym cannot be reversed by hashing
every possible phone number — there are only about a hundred million of them.
"""
def pseudonymise_source(raw_identifier: str, salt: str) -> str {
    if not salt {
        raise ValueError("a salt is required; an unsalted hash of a phone number is reversible");
    }
    normalised = re.sub(r"[^\d+]", "", raw_identifier) or raw_identifier.strip().lower();
    digest = hmac.new(salt.encode("utf-8"), normalised.encode("utf-8"), hashlib.sha256).hexdigest();
    return f"src:{digest[:16]}";
}
