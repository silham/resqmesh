"""Route `/news`: approved public bulletins."""

import from ..components.NewsFeed { NewsFeed }

def:pub News() -> JsxPage {
    <NewsFeed />
}
