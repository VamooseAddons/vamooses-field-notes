# Vamoose's Field Notes

**Paste coordinates from anywhere -- Wowhead, chat links, guides -- and
get clickable waypoints. Curate them into reusable libraries, share them
back as `/way` strings, and stop alt-tabbing between your browser and the
game.**

Vamoose's Field Notes is a capture-and-replay tool for coordinate-based
content. Whether you're farming rare spawns, doing a pet-collecting
circuit, hunting decor vendors, or following a guide that lists 40
locations -- paste the text once and hit Send Waypoints.

---

## Capture from anywhere

Open the window with `/vfn` (or the minimap button / addon compartment
icon) and paste any text that contains coordinates. The parser recognises:

- `/way 42.1 56.8 Spot name`
- `/way Harandar 42.1 56.8 Spot name` -- resolved by zone alias DB
  covering every Blizzard zone, city, and dungeon
- `/way #2480 42.1 56.8 Spot name` -- numeric mapID
- Multi-line Wowhead blocks with mixed zones -- each line inherits the
  nearest `Zone Name:` header above it
- Naked `42.1, 56.8` -- falls back to your current zone
- Chat-link map pins (`|Hworldmap:...|h`) -- paste the link straight in

Hit **Send Waypoints** to push the parsed list to your waypoint backend.
**Pin Here** is a one-click commit of your current player location as a
single-entry field note (independent of the paste box).

---

## The Library (find + curate)

Three-column workspace, designed for the way you actually use
coordinates:

**Libraries** -- your collections. Auto-captured notes land in the
Default library; promote them into themed libraries (Rare Spawns, Decor
Tours, Daily Routes) as you go via the `+ New library` button.
Right-click any library for Rename or Delete (Default is protected).

**Finder** -- cards in the active library, with:

- Search box -- title, note, source, zone all searchable
- Filter chips: **All / Ready / Has Note / Blocked**
- Sort cycle: **Recent / A-Z / Largest**
- Action row: Send Waypoints (whole card) / Move to.../ Delete
- Right-click any card for "Move to..." cross-library transfer

**Curator** -- the selected card, with three stat cards at the top
(COORDS / MAP / STATUS), an editable title and note (Save / Restore),
and a read-only coord-preview list. Click any single coord row to send
a one-shot waypoint, or use **Copy coords** to open a copy-friendly
multi-line dialog with one `/way` line per entry.

Status chips on every card surface state at a glance:

- **ready** -- entries resolve to a real map, safe to Send
- **blocked** -- card has no entries OR none have a resolvable map
- **note** -- card has a note attached
- **source** -- captured from paste (not Pin Here)
- **default** -- lives in the Default auto-capture library

---

## Stream history

The history list on the left of the window has a library dropdown above
it so you can flip between which library you're scrolling through
without leaving capture mode.

---

## Pre-loaded: Decor Vendors

Ships with a curated **Decor Vendors** library -- 92 zones, 216 vendor
coordinates -- sourced from the Housing Decor Guide vendor DB. Use it to
fast-route your decor shopping trips: pick a zone, hit Send Waypoints,
follow the pins.

Each zone-name card spans sub-maps where applicable (Boralus parent +
harbor inset, Harandar parent + Founder's Point sub-zone) with per-vendor
mapIDs so each waypoint routes to the right place.

The seeder is idempotent -- delete the library if you don't want it, or
`/vfn seed` to rebuild it.

---

## Slash commands

- `/vfn` -- toggle the window
- `/vfn debug` -- toggle debug logging
- `/vfn minimap` -- toggle the minimap button
- `/vfn seed` -- re-run library seeders
- `/vfn hardreset` -- wipe all SavedVariables

---

## Waypoint backends

Routes through whichever you have:

- **TomTom** -- preferred. Multi-pin support, per-coord arrow.
- **Blizzard pin** (`C_Map.SetUserWaypoint`) -- fallback when TomTom
  isn't installed. One super-tracked waypoint at a time is a game
  limitation, but the world-map pins for the open card paint for the
  whole set regardless of backend.

VFN doesn't replace your map or minimap; it just feeds waypoints into
whatever system you already use. SavedVariables are account-scoped, so
every character on the account sees the same libraries. Send operations
are combat-safe (bail out cleanly during lockdown).

---

## Support

- Discord: https://discord.gg/RWZaxJaHFP (`#fieldnotes` channel)
- Issues: https://github.com/VamooseAddons/vamooses-field-notes/issues
- More addons: https://www.curseforge.com/members/vamoose/projects

v0.1.0 -- first public release
