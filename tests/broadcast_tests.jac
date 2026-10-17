"""The alert broadcaster: format the three languages, and never let a bad send break
the loop."""

import from datetime { datetime, UTC }
import from resqmesh.adapters.broadcast.telegram { TelegramChannelBroadcaster, format_alert }
import from resqmesh.contracts.models { CommunityAlert }

def sample_alert(**over: any) -> CommunityAlert {
    base: dict[str, any] = {
        "alert_id": "AL-1",
        "template_id": "flood_warning",
        "slots": {"area": "Kolonnawa"},
        "text_si": "සිංහල පණිවිඩය",
        "text_ta": "தமிழ் செய்தி",
        "text_en": "Flood warning for Kolonnawa.",
        "target_gn_ids": ["KLN-003"],
        "approval_id": "AP-1",
        "issued_at": datetime(2026, 9, 26, 8, 0, tzinfo=UTC)
    };
    base.update(over);
    return CommunityAlert(**base);
}

def boom(c: str, t: str) {
    raise RuntimeError("network down");
}

test "format carries area and all three languages" {
    text = format_alert(sample_alert());
    assert "Kolonnawa" in text;
    assert "Flood warning for Kolonnawa." in text;
    assert "සිංහල පණිවිඩය" in text;
    assert "தமிழ் செய்தி" in text;
}

test "broadcast sends to the configured channel" {
    sent: list[tuple[str, str]] = [];
    TelegramChannelBroadcaster(
        chat_id="@resqmesh", send=lambda (c: str, t: str) -> None { sent.append((c, t)); }
    ).broadcast(sample_alert());
    assert len(sent) == 1;
    (chat, text) = sent[0];
    assert chat == "@resqmesh";
    assert "Kolonnawa" in text;
}

test "a failed send is swallowed not raised" {
    # Must return normally: the last mile can fail without stalling the incident.
    TelegramChannelBroadcaster(chat_id="@resqmesh", send=boom).broadcast(sample_alert());
}

test "missing area slot does not crash" {
    text = format_alert(sample_alert(slots={}));
    assert "Flood warning for Kolonnawa." in text;
}
