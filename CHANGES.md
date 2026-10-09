# Traccar QField Plugin — Changes Log

Summary of improvements made to `main.qml` for potential merge back into the main project.

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
| `trackMode` | 0 | 0 = add, 1 = keep most recent per device |
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
