"""Route `/`: the public landing page."""

import from ..components.PublicLanding { PublicLanding }

def:pub Index() -> JsxPage {
    <PublicLanding />
}
