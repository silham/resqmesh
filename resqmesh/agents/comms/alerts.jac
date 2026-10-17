"""Community alert composition: fixed templates, slot filling, rate limiting.

Public messages are the highest-stakes output the system has, so two rules from the
proposal are enforced structurally here:

* **Never free-form model output.** A public alert is a reviewed template with slots
  filled in: there is no code path that puts raw language-model text in front of the
  public. The `TEMPLATES` registry is the whole vocabulary.
* **Rate-limited by area.** `AlertRateLimiter` caps how often any one division can be
  alerted, so a runaway loop is structurally incapable of flooding the public with
  messages and causing alert fatigue.

A note on translation: the Sinhala and Tamil strings are **draft standard
civil-defence phrasings, pending a final native-speaker pass** before any real
deployment. They are good enough to demonstrate trilingual dispatch, and, because
they come from a fixed reviewed registry, never from the model, a reviewer edits
wording in one place without touching any decision logic. This is a demo asset, not
an approved public-safety translation.
"""

import from datetime { datetime, timedelta }

# --------------------------------------------------------------------------- #
# The template registry: the entire public-facing vocabulary.
# Each template is (english, sinhala, tamil); {slot} placeholders are filled from
# the caller's slot dict. SI/TA are pending native review (see module docstring).
# --------------------------------------------------------------------------- #

"""One reviewed public message in three languages, with the slots it needs."""
obj AlertTemplate {
    has template_id: str,
        en: str,
        si: str,
        ta: str,
        required_slots: list[str];
}

# DRAFT Sinhala/Tamil, pending a final pass by a native reviewer before any real
# deployment. These are standard civil-defence phrasings, good enough to demonstrate
# trilingual dispatch; the slots ({area}, {shelter}, {capacity}) are identical across
# languages so a reviewer edits wording without touching the fill logic.
glob TEMPLATES: dict[str, AlertTemplate] = {
    "evacuate_area": AlertTemplate(
        template_id="evacuate_area",
        en="EVACUATION ORDER for {area}. Move to {shelter} now. Do not cross flooded roads.",
        si="{area} සඳහා ඉවත් වීමේ නියෝගයයි. දැන්ම {shelter} වෙත යන්න. ජලයෙන් යටවූ මාර්ගවල ගමන් නොකරන්න.",
        ta="{area} பகுதிக்கு வெளியேற்ற உத்தரவு. இப்போதே {shelter} இடத்திற்குச் செல்லுங்கள். வெள்ளத்தில் மூழ்கிய சாலைகளைக் கடக்க வேண்டாம்.",
        required_slots=["area", "shelter"]
    ),
    "flood_warning": AlertTemplate(
        template_id="flood_warning",
        en="FLOOD WARNING for {area}. Water rising. Prepare to move to higher ground.",
        si="{area} සඳහා ගංවතුර අනතුරු ඇඟවීමයි. ජල මට්ටම ඉහළ යමින් පවතී. උස් බිමකට යාමට සූදානම් වන්න.",
        ta="{area} பகுதிக்கு வெள்ள எச்சரிக்கை. நீர்மட்டம் உயர்ந்து வருகிறது. உயரமான இடத்திற்குச் செல்லத் தயாராகுங்கள்.",
        required_slots=["area"]
    ),
    "stand_down": AlertTemplate(
        template_id="stand_down",
        en="ALL CLEAR for {area}. The warning is lifted. Follow local officials before returning home.",
        si="{area} සඳහා අනතුරු ඇඟවීම ඉවත් කර ඇත. ආපසු නිවෙස් වලට යාමට පෙර ප්‍රාදේශීය නිලධාරීන්ගේ උපදෙස් පිළිපදින්න.",
        ta="{area} பகுதிக்கான எச்சரிக்கை நீக்கப்பட்டது. வீடு திரும்பும் முன் உள்ளூர் அதிகாரிகளின் அறிவுரையைப் பின்பற்றுங்கள்.",
        required_slots=["area"]
    ),
    "shelter_open": AlertTemplate(
        template_id="shelter_open",
        en="Relief shelter open at {shelter} for {area} residents. Capacity {capacity}.",
        si="{area} වැසියන් සඳහා {shelter} හි සහන කඳවුර විවෘත කර ඇත. ධාරිතාව {capacity}.",
        ta="{area} மக்களுக்காக {shelter} இல் நிவாரண முகாம் திறக்கப்பட்டுள்ளது. கொள்ளளவு {capacity}.",
        required_slots=["area", "shelter", "capacity"]
    )
};

"""Raised when a template id is not in the reviewed registry."""
class UnknownTemplate(KeyError) {}

"""Raised when a required slot was not supplied. Better to fail than to broadcast a
message with an empty blank in it."""
class MissingSlot(KeyError) {}

"""Return (si, ta, en) with slots filled. Order matches the CommunityAlert fields.

Fails loudly on an unknown template or a missing slot: a public message with a hole
in it is worse than no message."""
def fill_template(template_id: str, slots: dict[str, str]) -> tuple[str, str, str] {
    template = TEMPLATES.get(template_id);
    if template is None {
        raise UnknownTemplate(template_id);
    }
    missing = [s for s in template.required_slots if s not in slots];
    if missing {
        raise MissingSlot(f"template {template_id!r} needs slots {missing}");
    }
    return (
        template.si.format(**slots),
        template.ta.format(**slots),
        template.en.format(**slots)
    );
}

# --------------------------------------------------------------------------- #
# Rate limiting
# --------------------------------------------------------------------------- #

"""Which templates a cooldown may not suppress. A stand-down is never rate-limited:
the cooldown exists to stop alert fatigue, and telling people a danger is over is the
one message that must never be held back because they heard from us recently."""
glob UNLIMITED_TEMPLATES: frozenset[str] = frozenset({"stand_down"});

"""Per-division cooldown between public alerts.

Stateful on purpose: it remembers when each area was last alerted and suppresses a
repeat inside the window. Injecting `now` keeps it deterministic and testable.

`seed` restores the cooldowns from the incident state, so they survive a restart.
Held only in process memory, a redeploy or an OOM reset every cooldown and the next
tick could alert an area that had just been alerted, and the suppression never
reached the audit trail, which makes a rate limit nobody can inspect not much of a
control."""
obj AlertRateLimiter {
    has min_interval: timedelta = timedelta(minutes=10),
        _last_sent: dict[str, datetime] = {};

    """Adopt the later of what we hold and what the state remembers."""
    def seed(last_sent: dict[str, datetime]) {
        for (gn, when) in last_sent.items() {
            held = self._last_sent.get(gn);
            if held is None or when > held {
                self._last_sent[gn] = when;
            }
        }
    }

    """For persisting into the incident state."""
    def cooldowns -> dict[str, datetime] {
        return dict(self._last_sent);
    }

    """Split target areas into (allowed, suppressed) without recording anything.

    Recording is a separate step so a suppressed area does not reset its own cooldown
    just by being asked about."""
    def filter_allowed(
        gn_ids: list[str], now: datetime, template_id: str = ""
    ) -> tuple[list[str], list[str]] {
        if template_id in UNLIMITED_TEMPLATES {
            return (list(gn_ids), []);
        }
        allowed: list[str] = [];
        suppressed: list[str] = [];
        for g in gn_ids {
            last = self._last_sent.get(g);
            if last is None or now - last >= self.min_interval {
                allowed.append(g);
            } else {
                suppressed.append(g);
            }
        }
        return (allowed, suppressed);
    }

    def record(gn_ids: list[str], now: datetime) {
        for g in gn_ids {
            self._last_sent[g] = now;
        }
    }
}
