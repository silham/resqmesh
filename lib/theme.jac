"""Mantine theme: a bright, high-contrast operations palette. Teal primary on a near-white
canvas; priority and hazard get their own semantic colours in `lib/format` so the map and
the queue read at a glance."""

import from "@mantine/core" { createTheme }

glob:pub TEAL: list[str] = [
    "#effcf9", "#d8f4ed", "#b3e7db", "#83d6c5", "#54bda9",
    "#2ea58f", "#188a77", "#0d7565", "#0b6255", "#084f45"
];

glob:pub theme: any = createTheme({
    "primaryColor": "teal",
    "primaryShade": 7,
    "colors": {"teal": TEAL},
    "fontFamily": "system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial, sans-serif",
    "defaultRadius": "md",
    "cursorType": "pointer"
});
