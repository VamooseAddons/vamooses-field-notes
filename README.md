# Vamoose's Field Notes

Paste coordinates from anywhere on the web, hit Send Waypoints, get pins
on your map. Curate them into reusable libraries you can come back to.

A World of Warcraft: Midnight addon for capturing and replaying
coordinate-based field notes -- pet-collecting routes from Wowhead, decor
vendor tours, leveling guides, rare-spawn circuits. Anything you can copy
as text becomes a clickable, organisable trip.

## Install

- **CurseForge:** https://www.curseforge.com/wow/addons/vamooses-field-notes
- **Manual:** download a zip from
  [Releases](../../releases), extract into
  `World of Warcraft/_retail_/Interface/AddOns/`.

## What it does

Open the Field Notes window with `/vfn` (or the minimap button / addon
compartment icon). Paste any text that contains coordinates -- the parser
pulls every `/way`, Wowhead block, chat-link pin, or naked `42.1, 56.8`
out of it. Hit **Send Waypoints** and the whole list ships to TomTom (if
you have it) or Blizzard's super-tracked pin.

Supported input shapes:

- `/way 42.1 56.8 Spot name` (naked decimals)
- `/way Harandar 42.1 56.8 Spot name` (zone name -- resolves against the
  alias DB; every Blizzard zone + city + dungeon is indexed)
- `/way #2480 42.1 56.8 Spot name` (explicit numeric mapID)
- Wowhead-formatted block paste (multiple lines, mixed zones -- each line
  inherits the nearest "Zone Name:" header)
- Chat-link map pins -- paste the `|Hworldmap:...|h` link straight in
- Naked `42.1, 56.8` -- the parser uses your current zone as fallback

## The Library

Every field note you Send (or Pin Here save) lands in a library. The
**Library** tab is a three-column workspace:

- **Libraries** -- your collections. Right-click any library for Rename
  or Delete (Default is protected). The Default library auto-collects
  every Send + every Pin Here.
- **Finder** -- cards in the selected library, with:
  - Search box (matches title, note, source, zone)
  - Filter chips: All / Ready / Has Note / Blocked
  - Sort cycle: Recent / A-Z / Largest
  - Action row: Send Waypoints (whole card) / Move to... / Delete
  - Right-click a card for Move to... cross-library transfer
- **Curator** -- the selected card. Stat cards on top
  (COORDS / MAP / STATUS), editable title + note, and a read-only
  coordinate preview list. Click any single coord row to send a
  one-shot waypoint; the **Copy coords** button opens a copy-friendly
  `/way` dialog for sharing back to chat.

Status chips on each card surface state at a glance:

- **ready** -- entries resolve to a real map, safe to Send
- **blocked** -- no entries OR no entry has a resolvable map
- **note** -- card has a note attached
- **source** -- captured from paste (not Pin Here)
- **default** -- lives in the Default auto-capture library

## Stream history

The stream rail on the left of the window is a running history of recent
captures. A library dropdown above the list lets you switch which
library's cards you're scrolling through -- handy when you want to glance
at "Decor Vendors" without leaving capture mode.

## Pre-loaded libraries

Ships with a curated **Decor Vendors** library -- 92 zones, 216 vendor
coordinates -- sourced from the Housing Decor Guide vendor DB. Use it to
fast-route decor shopping trips. The seeder is idempotent: delete the
library if you don't want it, or run `/vfn seed` to rebuild.

## Slash commands

- `/vfn` -- toggle the window
- `/vfn debug` -- toggle debug logging
- `/vfn minimap` -- toggle the minimap button
- `/vfn seed` -- re-run library seeders (rebuilds Decor Vendors if missing)
- `/vfn hardreset` -- wipe all SavedVariables

## Compatibility

Routes waypoints through whichever backend you have:

- **TomTom** -- multi-pin support, per-coord arrow. Preferred when present.
- **Blizzard pin** (`C_Map.SetUserWaypoint`) -- the single super-tracked
  user waypoint. Used when TomTom isn't installed; only the first entry
  in a multi-coord set is sent (the rest stay visible as pins on the
  world map when the card is open).

The world-map pins for the currently-open field note paint regardless of
which backend you use.

VFN doesn't replace your map or minimap -- it just feeds waypoints into
whatever system you already use. SavedVariables are account-scoped, so
every character on the account sees the same libraries.

## Support

- Discord: https://discord.gg/RWZaxJaHFP (`#fieldnotes` channel)
- Issues: https://github.com/VamooseAddons/vamooses-field-notes/issues

## License

MIT. See [LICENSE](LICENSE).
