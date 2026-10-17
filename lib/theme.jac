"""Mantine theme: a bright, high-contrast operations palette. Teal primary on a near-white
canvas; priority and hazard get their own semantic colours in `lib/format` so the map and
the queue read at a glance."""

import from "@mantine/core" { createTheme }

glob:pub TEAL: list[str] = [
    "#e6fcfb", "#d0f7f4", "#a1eee9", "#6ee4dd", "#48dcd3",
    "#31d7cd", "#1fd3c8", "#0bbbb1", "#00a79d", "#009088"
];

glob:pub theme: any = createTheme({
    "primaryColor": "teal",
    "primaryShade": 7,
    "colors": {"teal": TEAL},
    "fontFamily": "system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial, sans-serif",
    "defaultRadius": "md",
    "cursorType": "pointer"
});
