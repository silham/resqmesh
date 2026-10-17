"""Any path that matches no page: send the visitor to the front door rather than a dead end."""

import from ..components.PublicLanding { PublicLanding }

def:pub NotFound() -> JsxPage {
    <PublicLanding />
}
