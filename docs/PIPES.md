# Data pipes: staging, gates, verification queue

Muse's dev spec of 2026-10-28; Colin approved the direction the same day. Free public feeds land in **staging**
tables here. The gates decide which staged parcel + signal becomes a **verification-queue item**. Muse's lanes
claim and close those items through the agent door. Built one phase at a time; the file pipeline keeps running
until each phase lands.

## Colin's six rules, and where each one lives

| Rule | Where |
|---|---|
| Staging is not cards | Nothing in migration 0103 writes `leads`, `contacts`, texts or outreach. A verified `new` item is promoted by the lane through `add_prospects`. |
| A parcel alone is never a lead | Gate 5: an item needs a staged signal (`pipe_signals`), or reasons already on a card. |
| Conflicts are preserved | `pipe_conflicts`: the card's value and the pipe's, each with source and date. The card is flagged there and a `re_screen` item opens; the card itself is never written. |
| Every value carries its basis | `pipe_parcels`: assessed value with `assessment_year`, the file date (`vintage`), and the source; `pipe_sources.last_file_date` is the last file that still carried it. A verified value field must say `basis: assessed`. |
| Dedupe before create | `pipe_card_ids`: every card, by county + parcel id first, then by the same address (`addr_key(addr_main())`) in the same county and town. A match makes a `stack` or `re_screen`, never a `new`. |
| No fees, no WCCA | MPROP is the city's free file. Nothing here touches WCCA. |

## The gates (`pipe_screen`)

1. **County** in the 21 buy-box counties (`pipe_settings.buy_box_counties`, Muse's list of 2026-10-28).
2. **Type**: single family, duplex, or a condo by explicit classification (MPROP `LAND_USE` 8811). 3+ units, commercial, land and exempt are out. A unit count in the file beats the land-use group.
3. **Value**: assessed value strictly under $500,000 (`pipe_settings.value_cap`). No value = `value_missing`.
4. **Milwaukee map** (City of Milwaukee only): inside Muse's exclusion polygon = `map_excluded`; within 275 m of its edge = `held_buffer` for Colin's parcel ruling; a `clear` area (Riverwest: on or east of Holton St) cancels the band. No map loaded = `map_not_loaded`: nothing in the city is queued, never guessed.
5. **Distress**: one qualifying signal. Tax qualifies only at 2+ unpaid years. A DOR row (`pairs_only`) never qualifies alone.
6. **No freeze**: an active bankruptcy, a dead / do-not-contact card on the property, or a deceased owner of record with no live representative.

## Tables (migration 0103)

- `pipe_sources`: one row per feed, its last file date, sha and row count.
- `pipe_parcels`: one row per parcel per source; `use_class` is the gate's reading, the source's own codes are kept beside it. Never deleted: a parcel the file drops gets `gone_on`.
- `pipe_parcel_changes`: what each day's file changed: `new`, `owner`, `mailing`, `value`, `class`, `gone`, `back`, with before and after.
- `pipe_signals`: staged distress (phase 1b on). A row that leaves its source stays (a stack is history).
- `pipe_conflicts`, `pipe_queue`, `pipe_map_areas`, `pipe_runs`.

## The door (prospects scope)

`pipe_counts`, `pipe_queue`, `pipe_claim`, `pipe_item`, `pipe_close`, `pipe_set_map`. See `docs/AGENT_DOOR.md`.

Outcomes: **verified** (each field `{value, source, date}`), **killed** with a code, **held** with the blocker
named, **release**. A `held_buffer` item takes only Colin's ruling: `ruled_in` (back to open) or `ruled_out`.
A claim not closed in 24 hours goes back to open.

## Phase 1a: Milwaukee MPROP, daily (live 2026-10-28)

The laptop runs `python -m wpie.pipes.mprop` in the 1 AM nightly (WPIE repo, `wpie/pipes/mprop.py`). It fetches the
file once, sends only rows whose hash changed (1,000 per transaction, staging tables only), stamps parcels that
left the file, sets map points from the laptop's parcel-point cache, screens every parcel that has a card, a
signal, an owner change or a live item, and writes the counts to `pipe_runs`.

An owner change on a carded parcel opens a `re_screen` item; a card whose owner shares no name word with MPROP's
gets a conflict. Phase 1a stages no signals of its own (MPROP's distress columns are masked), so its only items
are re-screens until 1b brings vacant buildings.

## Phase 1b: Milwaukee vacant buildings and permits (live 2026-10-28)

`python -m wpie.pipes.signals` runs in the nightly after the MPROP step (migrations 0107, 0108).

- **Vacant buildings** (`mke.vacant`): WPIE already collects the city's list every day (`mke.city.vacant_buildings`),
  so the pipe publishes WPIE's records instead of asking the city again. One signal per registration
  (parcel:date opened). A registration is `active` while WPIE's latest successful run still saw it. One that leaves
  the list stays staged as history, but no longer qualifies a parcel or opens an item.
- **Permits** (`mke.permits`): the city's monthly permit work file, fetched when the last copy is 28 days old.
  It has addresses only, so it is matched to MPROP parcels by address. A permit is context on an item; it never
  qualifies a parcel or opens one (Colin's distress list has no permits).
- The spec said "CKAN API". data.milwaukee.gov's robots.txt disallows `/api/`, so the pipes use the dataset pages' own
  download links, as WPIE's collectors do.

First live run: 1,832 vacant registrations (1,770 on today's list), all on staged parcels, 144 on cards. 16,684
permit rows, 13,936 matched to a parcel by address, 103 on cards. With no map loaded, nothing in the City of
Milwaukee is queued yet. About 1,200 vacant-building parcels pass every other gate (1,113 new, 109 stacks).

## Not built yet

2 statewide V12, 3 county ArcGIS registry, 4 CourtListener + DOR.
