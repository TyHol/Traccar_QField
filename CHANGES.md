# Traccar QField Plugin — Changes Log

Summary of improvements made to `main.qml` for potential merge back into the main project.

---

# v0.7.3 (in development)

- **Auto-save catches up when the time window gets wider.** Each fix not yet in the positions layer is
  saved (matched by device and fix time), so widening e.g. 1 h → 3 h saves the earlier fixes too, and
  nothing is ever saved twice — also after a restart, as the layer is read first. Before, only fixes
  newer than the newest saved one went in.
- **A new time window or Refresh rewrites the saved tracks straight away**, longer or shorter, so they
  always match the window; Live updates rewrite only the tracks that got a newer fix. Before, a track
  waited for its device's next fix (or Save tracks).
- **The first auto-save after a start stays quick with a long history in the layer**: it reads only the
  saved fixes from the window's start on (and just the earlier part when the window widens), in one
  pass. A 500,000-fix layer: 0.2 s instead of 5.6 s in QGIS; QField read the whole layer once per device.
- **Automatic saving is at the top of Settings → Layers.**
- **Default names for points: a comma-separated list** (Settings → Connection), e.g. `Team 1, Team 2,
  Clue`. Adding a point offers them in a drop-down next to the name (the first is filled in, or the
  last name you sent); any other name can still be typed.
- Tests: 149 checks.

# v0.7.2 — Save geofences, safer sending, Live by default

- **Moving a device you didn't add asks first.** Send point / Add → Point with the name of a device that
  wasn't added from QGIS or QField (a real tracker, say) now asks "This moves '…' — move it?" before
  sending; points added from QGIS / QField (identifier `qgis-…`) still move without asking.
- **No empty devices left behind**: if Traccar refuses the first position of a point the plugin has just
  added, that new device is removed again.
- **Live is on by default** and remembered; **Refresh** shows only while Live is off; **Clear** is now
  **Clear map**.
- **Settings: Connection, Layers, Incident, Advanced.** *Incident* holds the time window 'From feature'
  layer and the Tag together (both are about the incident you're working on).
- **Faster loading**: a time window's fixes come in one route report for all devices (in batches of 50)
  instead of one request per device; servers that refuse it get one request per device as before.
- The version number lives only in `metadata.txt` and here (not in code comments).
- Settings from 0.2 / 0.3 are no longer migrated (eight old settings removed).

- **Save geofences** (Save in the Geofences tab): Traccar's geofences to layers chosen in Settings →
  Layers → Geofences — areas and circles (as polygons) to a polygon layer, lines to a line layer, with
  `geofence_id`, name, description, type, radius_m, speed_kmh, color, calendar, made_in, saved_at.
  Saving again replaces each one by `geofence_id`. `traccar_template.gpkg` gains `traccar_geofences`
  and `traccar_geofence_lines`. New icon `icons/save.svg`.
- **Save after every refresh and Live update** (Settings → Layers): only what's new — each shown
  device's new fixes (latest or every fix), its track kept to the most recent one, and geofences that
  changed. Waits for QFieldCloud syncs like Save; reads the newest fix already in the layer first, so
  nothing is saved twice.
  Long tracks back off by themselves: after a track rewrite, the next waits at least 20x as long as it
  took (at most 10 minutes), so writing never takes more than about 5% of the time; new positions are
  still saved on every refresh.

- **A sent geofence stays on the map** while Traccar saves it — *sending…* in the Geofences tab —
  instead of vanishing until the reload; Traccar's copy then replaces it (or, if Traccar refused it, it
  goes). Its edit / colour / delete buttons wait until it's saved. Same as the QGIS plugin.
- **A sent point shows at once too**: a dashed ring in the device's colour and "*name* (sending…)",
  until the first refresh or Live update after Traccar accepted it — then the real marker is there (in a
  past time window it simply goes). If Traccar refuses the point, it goes at once.
- Once Traccar accepts a sent point, the plugin **refreshes by itself every 2 s (up to 5 times), Live on
  or off,** until the real device shows. In a time window that ends in the past (custom dates, from
  feature) the point can't appear, so its stand-in goes at once with a note.
- Tests: 138 checks.

# v0.7.1 — Phones: fits the screen, tap to add, long-press to send

- **Nothing spills off the right of the main window on a phone.** Buttons and tick boxes squeezed into a
  narrow row drew their text past the window's edge. On a phone, *Clear* and *Add* are now icon buttons,
  leaving room for *Live*; the Show row wraps instead of squeezing if it ever must.
- **⋮** (choose the details a list shows) is now an icon — some phone fonts have no "⋮" character.
- **Adding by tapping the map works on phones.** Before QField 4.0 a finger tap on the map never reached
  plugins (only mouse / stylus clicks did), so *Add → Point / Area / Line / Circle* ignored taps on a phone.
  While adding, the plugin now catches map taps itself (one tap passed on by QField too counts once), and
  shows a **crosshair** at the map centre with an **Add here** / **Add corner** button: move the map to put
  the cross on the spot and tap it — works on every QField version.
- **Long-press the map → Send to Traccar.** QField's map menu (long-press on a phone, right-click on a
  computer) gets a Traccar Live button: *Point here*, *Circle here*, *Start an area here* or *Start a line
  here* at the pressed spot. Same as the QGIS plugin's right-click menu. Works from QField 3.3.
- New icons `icons/clear.svg`, `icons/more.svg` (Material Icons).
- Tests: the main window (both tabs), the send forms, *From layer* and every Settings page are checked at
  phone width (360) with phone-sized text — nothing may stick out or be squeezed; a real finger
  tap is tested without QField's tap forwarding. 113 checks.

---

# v0.7 — Geofences, and adding / deleting in Traccar

Same tools, form and rules as the QGIS plugin [Traccar_QGIS](https://github.com/TyHol/Traccar_QGIS) 0.4.0:
the same geofence marker, `qgis-…` identifiers and colour attribute.

### Geofences
- Traccar's **geofences** (areas, lines, circles) are drawn on the map with their names, each in **its own
  colour** (Traccar's `color` attribute, else orange). They never go grey like an old fix. *Geofences*
  under Show switches them on or off; they load with every Refresh / Live load.
- A **Geofences tab**: tick to show / hide each one (remembered, `hiddenGeofences`), tap its colour to pick
  another (saved in Traccar), the **pencil** to edit it, the target to centre the map on it, the bin to
  **delete it from Traccar** (always asked first; one made in Traccar gets an extra warning).
- **Edit** opens the send form filled in: name, description, speed limit, corridor width, calendar,
  colour and a circle's radius. *Save to Traccar* updates the geofence; its shape stays.

### Add to Traccar
- **Add** next to Clear:
  - **Point** — tap the map (or *My location*) and give a name. A new name adds a device in Traccar
    (identifier `qgis-<name>-<time>`, or your own) and sends the position through Traccar's OsmAnd port;
    an existing device's name moves that device. Points added this way have a bin in the device list.
  - **Area** / **Line** — tap each corner (*Undo*, *My location*), then *Done*.
  - **Circle** — tap the centre; radius 250, 500, 1000 m or any.
  - **From layer…** — a layer's features (all or one), named and described from fields. Any CRS, Z / M,
    multipart; holes are dropped; points become circles or points (devices); very detailed shapes are
    thinned to fit Traccar's limit.
- **One send form** for every shape, the same as the QGIS plugin's. Geofences: name, description, speed
  limit (km/h; Traccar stores knots), corridor width for lines, Traccar calendar and a colour. New points:
  identifier, category (map icon), group, phone, model and contact. Groups and calendars come from your
  Traccar server; the form scrolls on small screens.
- A geofence sent with the same name as one sent from QGIS or QField before **replaces** it.
- **Settings → Connection → Send points to** sets Traccar's OsmAnd address if it isn't port 5055 on the
  server (`sendUrl`).

### Main screen
- **Devices** and **Geofences** tabs, with counts. **⋮** on each tab chooses which details its list shows
  (devices: fixes and time span, speed, battery, location; geofences: type, made in, speed limit,
  description).
- **Show** fits on one row: Markers, Labels, Tracks, Geofences. GPS accuracy circles moved to
  Settings → Advanced.

### Also
- README, metadata and Help say clearly that this is **not an official Traccar plugin** and credit
  Traccar (Anton Tananaev and contributors). The plugin's homepage is now its GitHub page.
- The icons are Google's Material Icons; their Apache 2.0 licence is now included (`icons/`).
- Release zips are attached to the GitHub releases, no longer kept in the repository.
- Tests: 103 checks; the fake server also serves geofences, groups, calendars and the OsmAnd port.

---

# v0.6 — Show / hide devices, colours, grid references

Ported from the QGIS plugin [Traccar_QGIS](https://github.com/TyHol/Traccar_QGIS) v0.3.0, kept simple.

- **Tick a device to show or hide it.** Each row in the device list has a tick box. A hidden device
  is left off the map and out of **Save positions** / **Save tracks**, and stays hidden next time
  (`hiddenDevices`, by Traccar id). The *Devices* header is a tick box too: it shows "*n* of *m* shown"
  and shows or hides them all.
- **A colour per device.** Markers, labels, accuracy circles, tracks and the dot in the device list
  use one colour per device, worked out from its name the same way as the QGIS plugin, so a device
  has the same colour in both. Grey still means the last fix is older than the limit.
- **Location formats.** Settings → Advanced → *Location*: Lat / long (default), Degrees + minutes
  (`53° 21.900' N, 6° 18.600' W`), Irish Grid (`O 15904 34671`, EPSG:29903), UK Grid
  (`NS 45140 72887`, EPSG:27700) or Project CRS (easting, northing to 0.1 m; lat / long if the project
  CRS is geographic). Used under each device and by its copy button; a position outside the Irish or
  UK grid falls back to lat / long. Same formats and grid letters as the QGIS plugin
  (*Conversion_tools* uses the same grid letters). `locationFormat`: 0 lat / long, 1 Irish Grid,
  2 UK Grid, 3 degrees + minutes, 4 project CRS.
- **Tracks drawn more faithfully.** Before, a track over 1500 fixes was thinned evenly, which cut
  corners. Now fixes within about 1 m of the previous one (a parked device) are dropped first, and
  vertices less than a pixel apart on screen are skipped; a track is only thinned evenly if it is still
  over 5000 points. Saving always uses every fix, as before.
- Tests: 54 checks (was 39).

---

# v0.5 — Hide the map button, copy positions, icons that always show

- **Show icon on canvas** — the plugin now has a settings icon in QField's Plugins list
  (`configure()`). Turning the switch off hides the Traccar button from the map; Live tracking keeps
  running and the same screen has an **Open Traccar Live** button.
- **Copy a device's position** — each device row shows its latest fix as lat/long (WGS84, 6 decimals)
  with a copy-to-clipboard button.
- **Smaller main and settings screens** — about 30% shorter and 7% narrower so the map stays
  visible; the device list scrolls with a visible scrollbar, and device rows are more compact.
- **Show button on the map** is also in Settings → Advanced.
- The settings button is a cog; the "Long window — loading and drawing may be slow" note is gone.
- Dialog headers use QField's green (`Theme.mainColor`) with rounded top corners; the Markers /
  Labels / Tracks / Accuracy checkboxes are smaller.
- **Icons instead of emoji** — some devices have no emoji font, so buttons showed blanks. Header,
  Live / Stop, refresh, zoom-to, copy and Save buttons now use SVG icons from `icons/`; emoji in
  status text and help were replaced with words. The release zip must include the `icons/` folder.
- **Release zip renamed to `traccar_qfield-v0.5.zip`.** QField only strips a `-vX.Y` suffix when it
  names the install folder, so `Traccar_Qfieldv0.4.1.zip` and `Traccar_Qfieldv0.5.zip` installed as two
  separate plugins. Uninstall an older URL install once; later versions update in place.

---

# v0.4.1 — Bug fixes

- **Tracks rejected by 2D or Z-only line layers.** Lines were always built as LineStringZM; QGIS
  adds a missing Z / M on commit but never drops one, so saving into a plain 2D line layer (or one
  with Z but no M) failed with "geometry type is not compatible". Points and lines are now built
  with exactly the target layer's Z / M (`_layerDims()` reads `wkbType()`); points into a Z layer
  (e.g. QField's Notes) now carry the fix's altitude instead of 0.
- **Changing the time window during a load was ignored.** A load still running blocked the new
  one, and its result then replaced the window you had just picked. Each load now has a
  generation number; choosing a window always starts a fresh load and late replies are dropped.
- **Live reply after a window change.** A Live refresh in flight when the window changed could
  throw on the cleared window; it is now ignored.
- Saving reports "the layer did not accept …" instead of a silent "Saved 0" when no feature was
  accepted.
- **tests/qml/** — runs `main.qml` outside QField (stand-in QField modules, a test driver and a
  fake Traccar server, using PySide6): 39 checks covering loading, Live, every window type, saving
  into 2D / Z / M / ZM / reprojected layers, the QFieldCloud wait queue, every dialog and settings
  page, with zero QML warnings. `python tests/qml/run_tests.py`

---

# v0.4 — One time window, simpler navigation

v0.3 is on branch `v0.3`.

## One time window for everything
- A single **Time window** in the main dialog replaces the v0.3 trail length, the Save Tracks dialog window and the hidden 24 h look-back for "points per device".
- **What is on the map is what gets saved.** Tracks drawn = every fix inside the window; **〰 Save tracks** writes those lines, **📍 Save positions** writes the markers (latest fix) or every fix in the window.
- Choices: Last 15 min … Last 3 months (moving), **Custom dates…** and **From feature…** (inline controls + *Show this window*).
- **Live** keeps a moving window up to date (new fixes appended, old ones dropped). A window that ends in the past cannot change, so Live pauses and markers show each device's last fix in the window. A custom/feature window that runs into the future (or an ongoing feature) keeps updating until its end.
- **🔄** loads the window once; **Clear** removes everything from the map.
- Device rows show fixes in the window and their time span, plus speed / battery.
- Removed: Save Tracks dialog, Fetch & preview step, orange preview overlay, session history list, `trailMinutes`, `pointsPerDevice`.

## Settings: list of short pages
- Settings opens on a list — **Connection, Layers, Tag, Advanced** — each with a one-line summary and warnings (e.g. "⚠ Nothing to save to yet", "✕ wrong username or password"). Tapping opens that page; ← goes back.
- **No Save button**: every change applies immediately (text fields when editing finishes, or on ← / ✕).
- The main dialog opens Settings at the right page: the "Positions → … · Tracks → …" line opens Layers; the error banner and first-run box open Connection.
- Event-layer setup ("From feature") moved to Advanced; the tag got its own page.

## Small screens
- Dialogs are full-screen below 520 px wide, inset by QField's `sceneTopMargin` / `sceneBottomMargin` (status / navigation bars); a floating panel on wider screens.
- Main dialog: time window and controls at the top, Save buttons at the bottom, only the device list scrolls.
- First-run box ("Getting started") until a server and account are set.

## Help
- Rewritten for the new layout: Getting started, Time window, Live / 🔄 / Clear, On the map, Saving, Times, Session tag.

## cfg Properties (v0.4)

| Property | Default | Purpose |
|---|---|---|
| `windowMinutes` | 60 | > 0 = Last N minutes, -1 = custom dates, -2 = from feature |
| `customFrom` / `customTo` | "" | Custom window, local "YYYY-MM-DD HH:MM" |
| `eventFeatureFid` | -1 | Feature chosen for "From feature" |
| `featureSpan` / `featureDuration` | 0 / 120 | start→end, start + duration, end − duration (minutes) |
| `pointsMode` | 0 | 0 = latest fix per device, 1 = every fix in the window |
| `v4Migrated` | false | One-time v0.3 → v0.4 migration (`trailMinutes` → `windowMinutes`, `pointsPerDevice > 1` → `pointsMode = 1`) |

Unchanged: connection, overlay toggles, layer / name-field / track-mode, tag and event-layer settings.

---

# v0.3 — Live overlay + on-demand saving

v0.2 is preserved as git tag `v0.2-backup` and in `backup/main_v0.2.qml`.

## Overview

| Part | Behaviour | Writes to file? |
|---|---|---|
| **Live overlay** | Markers, labels, accuracy circles and trails drawn on the map canvas, refreshed every N seconds | No |
| **📍 Save positions** | Latest fix (or most recent N fixes) per device → points layer | Only when pressed |
| **〰 Save tracks** | Pick a time window → *Fetch & preview* (dashed on map) → *Save* → one line per device | Only when pressed |

Layers A / B / C, layer B culling, the auto-write timer and the Fetch Logs point cap are removed.
On first start, v0.2 settings are migrated: B (or A) → points layer, C → tracks layer.

## Live overlay

- Polls `/api/devices` + `/api/positions` every `liveIntervalSec` (default 10 s). Errors are toasted once per error streak and shown in the main dialog banner instead of every poll.
- **Markers** — blue when the last fix is newer than `staleMinutes` (default 10), grey otherwise. Tap a marker → toast with name, fix age, speed, battery (via `pointHandler.registerHandler`).
- **Trails** — in memory only. Seeded from `/api/positions?deviceId&from&to` for the last `trailMinutes` when live starts (so they appear complete), then extended by each poll and trimmed to the window.
- **Preview** — tracks fetched in the Save Tracks dialog, drawn dashed orange.
- Every overlay has its own on/off checkbox in the main dialog (Markers, Labels, Accuracy, Trails, Preview).
- Drawn with `QtQuick.Shapes` + `mapSettings.coordinateToScreen()`, re-placed on `extentChanged` / `rotationChanged` / `outputSizeChanged`, re-projected on `destinationCrsChanged`. Trails / previews are decimated for drawing only (1000 / 1500 vertices); saved tracks keep every point.
- Accuracy circles are hidden when the map CRS is geographic (degrees).

## Save positions

- `pointsPerDevice = 1` → current fix per device. `> 1` → most recent N fixes from the last 24 h per device; a device with no fixes in that time still gets its last known fix.
- Always adds features.

## Save tracks

- Time window: Time period / Custom dates / From feature (unchanged).
- Two steps: **Fetch & preview**, then **Save** (saves exactly what was previewed).
- One LineStringZM per device per save (Z = altitude, M = epoch seconds), points ordered by `fixTime` — fixes v0.2's out-of-order vertices when a historic fetch was appended to a live track.
- `trackMode`: **0 = add** a new track per device every save (keep all); **1 = keep most recent** — earlier tracks of the same `device_id` are deleted first (needs a `device_id` field, otherwise falls back to add).
- Fields: `device_id, name, start_time, last_update, from_time, to_time, n_points, saved_at` + tag field.

## QFieldCloud guard (rewritten)

- **v0.2 guard never fired:** it called `mainWindow.findChild(...)`, which does not exist on QML objects; the exception was swallowed by `try/catch` so it always returned "not syncing". v0.3 uses `iface.findItemByObjectName()`.
- Busy = `cloudConnection.state === 1` (Busy) **or** `cloudProjectsModel.currentProject.status` is neither Idle nor Failing — the same rule QField uses in `QfCloudProjectsModel::busyProjectIds()`.
- `ProjectStatus` numbering changed between QField versions (4.0 added `Pushing`, 4.3 added `Creating`), so `Failing` is looked up by name (`QFieldCloudProject.Failing`, legacy name still registered in 4.3) instead of a hard-coded number. `Idle` is 0 in every version.
- Writes are **queued, not skipped**: they run as soon as cloud is idle (checked every 3 s), are cancelled after 10 min, and the main dialog shows "Waiting for QFieldCloud sync…". Relevant now that QField 4.x can auto-push on a timer.
- Source checked against QField v3.3 → v4.3.5 (2026-09-30). Note 4.3 renamed the cloud files: `src/core/qfieldcloud/qfcloudconnection.h`, `qfcloudproject.h`, `qfcloudprojectsmodel.h`; main QML is now `src/app/qml/QgisMobileapp.qml`.

## Time handling

| Where | How time is held |
|---|---|
| Traccar API | ISO 8601 UTC, e.g. `2026-10-09T08:15:30.000+00:00`; `from`/`to` query params sent as UTC ISO |
| Plugin → layer | Always a UTC ISO string (`…Z`). A GeoPackage DateTime field parses it as UTC (GPKG stores UTC; QGIS's OGR provider also converts local → UTC for GPKG). A Text field keeps an unambiguous timestamp. |
| Plugin UI | `Qt.formatDateTime()` on a JS Date → device local time, with the summer-time rule for that date |
| QField forms | DateTime editor widget formats with `Qt.formatDateTime()` → **local time** |
| QGIS desktop / QField labels & display expressions | GPKG DateTime reads back as UTC → shown as UTC, e.g. `2026-10-09 08:15:30 (UTC)` |

- New optional Text fields `fix_local` (points), `start_local` / `last_local` (tracks): local wall-clock time at save time, e.g. `2026-10-09 09:15:30 BST`. For QGIS desktop / CSV exports. Filled only if the field exists.
- For a true local DateTime in QGIS labels / virtual fields: `datetime_from_epoch(epoch("fix_time"))` (works in all QGIS 3.x; `convert_timezone()` only exists in QGIS 4).
- "From feature" times are normalised to UTC ISO before use. Fixes v0.2 sorting the feature list by text like `Fri Oct 09…` (alphabetical by weekday, not newest-first). Text times without an offset are read as local; date-only values as local midnight.

## Other fixes

- `commitChanges()` result is checked; failures roll back and report.
- New field `accuracy_m` on points.
- `tools/make_template_gpkg.py` builds `traccar_template.gpkg` with both layers and all fields (`tag` field included for the session tag).

## cfg Properties (v0.3)

| Property | Default | Purpose |
|---|---|---|
| `liveIntervalSec` | 10 | Overlay refresh (s) |
| `trailMinutes` | 30 | On-screen trail length |
| `staleMinutes` | 10 | Marker turns grey after this |
| `showMarkers` / `showLabels` / `showAccuracy` / `showTrails` / `showPreview` | true / true / false / true / true | Overlay toggles |
| `pointsLayerName` | "" | Points layer |
| `pointsPerDevice` | 1 | Fixes per device per save |
| `tracksLayerName` | "" | Tracks layer |
| `trackMode` | 0 | 0 = add, 1 = keep most recent per device (matched by `device_id`, else by the device name field) |
| `pointsNameField` / `tracksNameField` | "" | Extra text field that receives the device name (e.g. `title` on QField's built-in Tracks layer). The picker lists only text fields — types are read via QField's `FeatureModel` (Field role) + `LayerUtils.fieldType()`, falling back to all fields if that is unavailable. |
| `v3Migrated` | false | One-time v0.2 → v0.3 settings migration |

Removed: `intervalMin`, `appendTrack`, `cullByCount`, `cullMaxPerDevice`, `cullByAge`, `cullAgeMinutes`, `fetchMaxPoints`, `fetchLimitPts`, `fetchHistory`, `lastFetchIso`, `incidentRefExpr`, `appendMode`. `liveLayerName`, `appendLayerName`, `lineLayerName`, `pointLayerName` are read once for migration.

---

# v0.2

## 1. Settings Dialog — Paged Navigation

**What:** Replaced a single long scrolling settings page with 4 radio-button tabs.

**Tabs:**
- **Connection** — server URL, username, password, refresh interval, test button
- **Layers** — A / B / C layer pickers with clear descriptions
- **Feature** — event layer picker for "Fetch from Feature"
- **Session Tag** — tag text and field picker

**Why:** The single-page layout was too long to use comfortably on a phone.

---

## 2. Layer Labels (A / B / C)

**What:** All layer pickers now clearly labelled:
- **A — Live points** — cleared and replaced every fetch, one point per device
- **B — Accumulated points** — positions appended, never deleted, builds full history
- **C — Tracks** — one line feature per device, extended with each fetch

**Why:** Previously it wasn't clear what each layer did.

---

## 3. "— no layer —" De-select Option

**What:** All layer combo boxes (A, B, C, Event layer) now include a "— no layer —" first option. Selecting it disables writes to that layer.

**Why:** Once a layer was selected there was previously no way to de-select it.

---

## 4. Fixed: Event Layer Picker Blank

**What:** `populateAllLayers()` was calling `lyr.fields.count()` which throws in QML (it's a property, not a method). Fixed to `lyr.fields.names.length > 0`.

The `try/catch` was silently swallowing the error, leaving the picker empty.

---

## 5. Session Tag — Plain Text (Expression Evaluator Removed)

**What:** Replaced a ~182-line mini QGIS expression evaluator with a simple plain text field. User types a tag value (e.g. `FIRE-2026-001`) and it is stamped verbatim onto every A, B and C feature written.

**Why:** The expression evaluator was complex, confusing and largely unnecessary.

**cfg properties:**
- `incidentRefEnabled` (bool) — master on/off
- `sessionTag` (string) — the text value
- `incidentRefField` (string) — which field on B to write it into

---

## 6. Fetch Logs Dialog — Simplified

**What:** Major simplification of the Fetch Logs dialog:

- **Removed** device selector — always fetches all devices
- **Removed** "Write to" checkboxes — uses whatever layers are configured in Settings. Shows a read-only "Writes to: B — layerName, C — layerName" info line instead
- **Removed** separate fetch log dialog — session history moved to bottom of Fetch Logs page
- **Renamed** "Quick range" → **Time period**, "Date Range" → **Time Window**

**Time Window options:**
- **Time period** — preset dropdown: last 15 min → last 3 months
- **Custom dates** — YYYY-MM-DD or YYYY-MM-DD HH:MM
- **From feature** — derives time window from a selected feature's date fields

---

## 7. Fetch from Feature — Auto Session Tag

**What:** When fetching from a feature with "Use display field as session tag" enabled, the selected feature's display field value (e.g. `incident_ref`) is automatically used as the session tag for the positions written in that fetch.

**How it works:**
- `plugin.fetchTagOverride` property set before writes, cleared after
- `_writePointsToLayer` and `_writeLineFeature` check override first, fall back to `cfg.sessionTag`
- Two linked checkboxes keep Feature page and Session Tag page in sync:
  - Feature page: ☐ "Use display field as session tag when fetching from this feature"
  - Session Tag page: ☐ "Use display field as tag when fetching from a feature"
  - Ticking either one also enables the Session Tag master checkbox

---

## 8. Navigation — Settings ↔ Fetch Logs

**What:** Both dialog headers have a switch button:
- Settings header: "Fetch" button → opens Fetch Logs
- Fetch Logs header: 🔧 button → opens Settings

Main page controls row: **▶ Start** | **↻ Now** | **Fetch**

---

## 9. Session Fetch History

**What:** Every fetch (auto and manual) is logged in `plugin.fetchLog` and displayed at the bottom of the Fetch Logs dialog under "── Fetch History ──".

Each entry shows: time, devices found/online, total positions, per-device breakdown (name, status, pts, last fix location and time).

**Function:** `_addToFetchLog(positions, deviceInfo, isManual, isHist, fromIso, toIso)`

---

## 10. start_time / last_update on Track Features

**What:** `_writeLineFeature()` now accepts a `positions` array and writes:
- `start_time` — fixTime of the earliest position
- `last_update` — fixTime of the most recent position

These are written if the field exists in the layer (silently skipped if not).

---

## 11. Cloud Sync Guard

> **Superseded in v0.3** — this version never fired (`findChild` is not callable from QML). See the v0.3 QFieldCloud guard above.

**What:** All layer writes are skipped if a QField Cloud sync is in progress.

**How:**
```js
function _isSyncing() {
    try {
        var cc = mainWindow.findChild("cloudConnection")
        if (cc === null || cc === undefined) return false
        return cc.state === 1   // ConnectionState::Busy
    } catch(e) {}
    return false
}
```

**Source verified** from QField source:
- `objectName: "cloudConnection"` — `src/qml/qgismobileapp.qml:5111`
- `ConnectionState { Idle = 0, Busy = 1 }` — `src/core/qfieldcloud/qfieldcloudconnection.h`

Applied at the top of `_updateLiveLayer`, `_updateAppendLayer`, `_cullAppendLayer`, `_updateLineLayer`.

Fails silently (returns false) on non-cloud projects — no impact on local use.

---

## 12. Performance — Live Fetch Simplified

**What:** Removed "history mode" from the live auto-fetch entirely.

**Before:** Could be configured to pull all positions since the last fetch — with 10,000+ points on the server this caused OOM and app crashes.

**After:** Live fetch (`fetchAll()`) always calls `/api/positions` with no date range. Traccar returns exactly **one fix per device** (the last known position). This is always a tiny payload regardless of server history.

- Layer A: replaced with latest fix
- Layer B: latest fix appended
- Layer C: track extended with latest fix

**Bulk historical pulls** remain available via the Fetch Logs dialog (user-initiated, with point limit cap in Advanced).

---

## 13. UI Fixes (Android/Mobile)

- **Radio buttons** — changed from single-row `RowLayout` to `GridLayout` (2 columns) so labels don't truncate on narrow screens
- **Dialog y positions** — `Math.max(52, ...)` ensures dialogs always clear the Android status bar
- **Spacing** — reduced throughout (6→3, 8→4, spacer Items halved)
- **▸/▾** — replaced with `+`/`-` (Unicode arrows don't render on all Android fonts)
- **↻** — replaced with 🔄 emoji (renders reliably on Android)

---

## 14. Help Dialog

Rewritten to be brief — four short sections: Buttons / Layers / Fetch Logs / Session Tag. Fits on one screen.

---

## Files

| File | Purpose |
|---|---|
| `main.qml` | The QField plugin — all changes are here |
| `CHANGES.md` | This document |

## cfg Properties Added

| Property | Type | Default | Purpose |
|---|---|---|---|
| `useDisplayAsTag` | bool | false | Use feature display field as session tag |
| `sessionTag` | string | "" | Plain text tag stamped on all written features |
| `incidentRefEnabled` | bool | false | Master enable for session tagging |
| `incidentRefField` | string | "" | Field on layer B to write tag into |
| `eventLayerName` | string | "" | Layer for "From feature" picker |
| `eventDisplayField` | string | "" | Display field shown in feature combo |
| `eventStartField` | string | "" | Start datetime field on event features |
| `eventEndField` | string | "" | End datetime field on event features (optional) |

## cfg Properties Kept for Migration Only (No Longer Used)

| Property | Notes |
|---|---|
| `fetchHistory` | History mode removed from live fetch |
| `lastFetchIso` | No longer used (history mode removed) |
| `incidentRefExpr` | Expression evaluator removed |
| `pointLayerName` | Migrated to `liveLayerName`/`appendLayerName` |
| `appendMode` | Migrated |
