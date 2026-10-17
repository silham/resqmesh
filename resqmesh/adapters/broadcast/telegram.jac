"""Deliver an approved alert to a public Telegram channel: the last hop.

By the time an alert reaches here it is already composed by A6, trilingual, bound to
a reviewed template and Tier-C approved (`CommunityAlert.approval_id`: no approval, no
broadcast). This adapter does one thing: format the three languages into one message
and send it to a channel the bot administers.

Delivery is **best-effort**: a failed send is logged, never raised, so a flaky network
or a mis-set channel can never stall the incident loop. The broadcaster takes a `send`
callable rather than importing the service's Telegram client, so the adapter layer
stays free of any dependency on the service layer.
"""

import logging;
import from resqmesh.contracts.models { CommunityAlert }

glob log = logging.getLogger("resqmesh.adapters.broadcast.telegram");

"""One message, all three languages, headed by the area: the public bulletin."""
def format_alert(alert: CommunityAlert) -> str {
    area = alert.slots.get("area", "");
    header = f"🚨 ResQ-Mesh — {area}".rstrip(" —");
    return "\n\n".join([part for part in [header, alert.text_en, alert.text_si, alert.text_ta] if part]);
}

"""Sends each approved alert to one Telegram channel (`@name` or numeric id)."""
obj TelegramChannelBroadcaster {
    has chat_id: str,
        send: Callable[[str, str], None];  # (chat_id, text) -> None

    def broadcast(alert: CommunityAlert) {
        try {
            self.send(self.chat_id, format_alert(alert));
        } except Exception as exc {
            # The last mile must never break the loop.
            log.warning("alert %s not broadcast: %s", alert.alert_id, exc);
            return;
        }
        log.info("alert %s broadcast to %s", alert.alert_id, self.chat_id);
    }
}
