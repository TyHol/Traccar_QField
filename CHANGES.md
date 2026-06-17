# Traccar QField Plugin — Changes Log

Summary of improvements made to `main.qml` for potential merge back into the main project.

---

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
