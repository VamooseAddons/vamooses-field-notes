# Vamoose's Field Notes

Paste coordinates from anywhere on the web, hit Send, and your party gets
waypoints.

A World of Warcraft: Midnight addon for capturing and replaying
coordinate-based field notes -- pet-collecting routes from Wowhead, decor
vendor tours, leveling guides, rare-spawn circuits. Anything you can copy
as text becomes a clickable, organisable, shareable trip.

## Install

- **CurseForge:** https://www.curseforge.com/wow/addons/vamooses-field-notes
- **Manual:** download a zip from
  [Releases](../../releases), extract into
  `World of Warcraft/_retail_/Interface/AddOns/`.

## What it does

Open the Field Notes window with `/vfn` (or the minimap button). Paste any
text that contains coordinates -- the parser pulls out every `/way`,
Wowhead block, chat link, or naked `42.1, 56.8` it can find. Hit **Send
Waypoints** and the whole list ships to TomTom, Blizzard's pin system, or
the in-game map (whichever you have).

Supported input shapes:

- `/way 42.1 56.8 Spot name`
- `/way Harandar 42.1 56.8 Spot name`
- `/way #2480 42.1 56.8 Spot name` (numeric mapID)
- Wowhead-formatted block paste (multiple lines, mixed zones)
- Chat-link map pins (paste the link straight in)
- Naked decimals: the parser uses your current zone as fallback

## The Library

Every field note you Send (or "Pin Here" save) lands in a library. The
**Library** tab is a three-column workspace:

- **Libraries** -- your collections. Right-click for Rename / Delete.
  The Default library auto-collects every Send.
- **Finder** -- cards in the selected library, with search, filter
  chips (All / Ready / Has Note / Blocked), and a sort cycle
  (Recent / A-Z / Largest).
- **Curator** -- the selected card. Stat cards on top, editable title +
  note, and a read-only coordinate preview. Click a coord row to send a
  single waypoint; the **Copy coords** button opens a copy-friendly
  `/way` dialog for sharing.

Status chips on each card tell you whether a note is **ready** to send,
has a **note** attached, came from a **source** paste, or is the
**default** library's auto-capture.

## Pre-loaded libraries

Ships with a curated **Decor Vendors** library -- 92 zones, 200+ vendor
coordinates, courtesy of the Housing Decor Guide data. Use it to fast-route
your decor shopping trips. (Disable, rename, or delete it like any other
library.)

## Slash commands

- `/vfn` -- toggle the window
- `/vfn debug` -- toggle debug logging
- `/vfn minimap` -- toggle the minimap button
- `/vfn seed` -- re-run library seeders (rebuilds Decor Vendors if missing)
- `/vfn hardreset` -- nuke all SavedVariables (confirmation required)

## Compatibility

Routes waypoints through whichever backend you have, in order of
preference:

1. **TomTom** -- full multi-pin support, per-coord arrow.
2. **Blizzard map pins** -- one pin at a time (game limitation), but
   no addon dependency.
3. **In-game map** -- fallback display only.

VFN doesn't replace your map or your minimap; it just feeds waypoints
into whatever system you already use.

## Support

- Discord: https://discord.gg/RWZaxJaHFP
- Issues: https://github.com/VamooseAddons/vamooses-field-notes/issues

## License

MIT. See [LICENSE](LICENSE).
