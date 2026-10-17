"""Route `/report`: the public emergency report form."""

import from ..components.ReportForm { ReportForm }

def:pub Report() -> JsxPage {
    <ReportForm />
}
