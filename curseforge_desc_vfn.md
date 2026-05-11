# Vamoose's Field Notes

**Paste coordinates from anywhere -- Wowhead, chat links, guides -- and
get clickable waypoints. Curate them into reusable libraries, share them
back as `/way` strings, and stop alt-tabbing between your browser and the
game.**

Vamoose's Field Notes is a capture-and-replay tool for coordinate-based
content. Whether you're farming rare spawns, doing a pet-collecting
circuit, hunting decor vendors, or following a guide that lists 40
locations -- paste the text once, get a Send-Waypoints button, and your
party gets pings.

---

## Capture from anywhere

Open the window with `/vfn` (or the minimap button) and paste any text
that contains coordinates. The parser recognises:

- `/way 42.1 56.8 Spot name`
- `/way Harandar 42.1 56.8 Spot name` (resolved by zone alias DB --
  1500+ Blizzard zones supported)
- `/way #2480 42.1 56.8 Spot name` (numeric mapID)
- Multi-line Wowhead blocks with mixed zones (each line resolves
  against its nearest zone header)
- Naked `42.1, 56.8` -- falls back to your current zone
- Chat-link map pins -- paste the link straight in

Hit **Send Waypoints** and the whole list ships to TomTom (preferred),
Blizzard's pin system, or the in-game map (fallback). Or use **Pin Here**
for a one-click save of your current spot.

---

## The Library (find + curate)

Three-column workspace, designed for the way you actually use
coordinates:

**Libraries** -- your collections. Auto-captured notes land in the
Default library; promote them into themed libraries (Rare Spawns, Decor
Tours, Daily Routes) as you go. Right-click any library for Rename or
Delete.

**Finder** -- cards in the active library, with:

- Search box -- title, note, source, zone all searchable
- Filter chips: **All / Ready / Has Note / Blocked**
- Sort cycle: **Recent / A-Z / Largest**
- Right-click any card for "Move to..." cross-library transfer

**Curator** -- the selected card, with three stat cards at the top
(coords / map count / status), an editable title and note, and a
read-only coord preview list. Click any single coord to send a one-shot
waypoint, or use **Copy coords** to open a copy-friendly `/way` dialog
for sharing back to chat.

Status chips on every card surface state at a glance:

- **ready** -- entries resolve to a real map, safe to Send
- **note** -- card has a note attached
- **source** -- captured from paste (not Pin Here)
- **default** -- still in the auto-capture inbox

---

## Pre-loaded: Decor Vendors

Ships with a curated **Decor Vendors** library -- 92 zones, 200+ vendor
coordinates, sourced from the Housing Decor Guide. Use it to fast-route
your decor shopping trips: pick a zone, hit Send Waypoints, follow the
pins.

The seeder is idempotent and re-runnable -- delete the library if you
don't want it, or `/vfn seed` to rebuild it.

---

## Slash commands

- `/vfn` -- toggle the window
- `/vfn debug` -- toggle debug logging
- `/vfn minimap` -- toggle the minimap button
- `/vfn seed` -- re-run library seeders
- `/vfn hardreset` -- wipe all SavedVariables (confirmation required)

---

## Compatibility

Routes waypoints through whichever backend you have, in order of
preference: **TomTom** (full multi-pin), **Blizzard map pins** (one at a
time), **in-game map** (display fallback). VFN doesn't replace your map
or minimap; it just feeds waypoints into whatever system you already use.

---

## Support

- Discord: https://discord.gg/RWZaxJaHFP
- Issues: https://github.com/VamooseAddons/vamooses-field-notes/issues
- More addons: https://www.curseforge.com/members/vamoose/projects

v0.1.0 -- first public release
