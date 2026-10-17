"""Route `/responder`: the vehicle operator's dispatch screen."""

import from ..components.ResponderDispatch { ResponderDispatch }

def:pub Responder() -> JsxPage {
    <ResponderDispatch />
}
