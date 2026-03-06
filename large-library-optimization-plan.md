# Large Library Performance Optimization Plan

## Context
The app has 10 performance issues that become severe with large libraries (10K-100K+ songs). The user wants visual lists (queue, CarPlay) to load in chunks of ~50, and all other listed issues addressed.

## Files to Modify
1. `Cosmos Music Player/Services/DatabaseManager.swift` — new helper functions
2. `Cosmos Music Player/Services/PlayerEngine.swift` — originalQueue type, save cap, restore N+1
3. `Cosmos Music Player/Views/Player/QueueManagementView.swift` — artist cache
4. `Cosmos Music Player/Views/Library/LibraryViews.swift` — progressive loading for All Songs
5. `Cosmos Music Player/CarPlaySceneDelegate.swift` — full rewrite to on-demand loading
6. `Cosmos Music Player/Services/AppCoordinator.swift` — batch queries for playlist ops
7. `Cosmos Music Player/Services/CloudDownloadManager.swift` — query optimization, download cap

---

## Phase 1: Database Helpers (foundation for later phases)

**DatabaseManager.swift** — Add new functions after existing `getTracksByStableIds` (line 628):

1. **`getTracksByStableIdsPreservingOrder(_ stableIds: [String]) -> [Track]`** — wraps existing batch query but returns tracks in input ID order (needed for queue restore)
2. **`getAllArtistNamesById() -> [Int64: String]`** — single query returning all artist ID→name pairs (used as cache by queue view and CarPlay)
3. **`getFavoriteTracks(excludingFormats:) -> [Track]`** — query favorite tracks directly, filtering out incompatible formats (used by CarPlay favorites tab)
4. **`getTracksPaginated(limit:offset:excludingFormats:) -> [Track]`** — paginated track fetch for CarPlay All Songs (ORDER BY title, LIMIT/OFFSET)
5. **`getTrackCount(excludingFormats:) -> Int`** — total compatible track count for CarPlay pagination

---

## Phase 2: Shuffle Memory Fix (issue #2)

**PlayerEngine.swift** — Change `originalQueue` from `[Track]` to `[String]` (stable IDs only).

Locations to update:
- **Line 30**: Declaration `private var originalQueue: [Track]` → `[String]`
- **Line ~1659** (`playTrack`): `originalQueue = playbackQueue` → `.map { $0.stableId }`
- **Line 1774** (`toggleShuffle`): same change
- **Lines 1797-1809** (`restoreOriginalQueue`): batch-fetch tracks via `getTracksByStableIdsPreservingOrder()` instead of using stored `[Track]`
- **Line 2641** (`savePlayerState`): `originalQueue.map { $0.stableId }` → just `originalQueue` (already strings)
- **Lines 2715-2724** (`restoreUIStateOnly`): remove the N+1 DB fetch loop for originalQueueTracks, assign IDs directly
- **Lines 2830-2839** (`restorePlayerState`): same as above

**Memory savings**: ~10-15MB for 50K track queue (eliminates duplicate Track structs).

---

## Phase 3: Queue State Persistence Fix (issue #4)

**PlayerEngine.swift** — Two changes in `savePlayerState()` (line 2626):

1. **Cap saved queue to 2000 IDs** centered around `currentIndex`. Huge queues (50K) won't bloat UserDefaults.
2. **Fix N+1 in restore functions**: Replace the `compactMap` per-ID query loops in `restoreUIStateOnly()` (line 2709) and `restorePlayerState()` (line 2824) with single `getTracksByStableIdsPreservingOrder()` calls.

---

## Phase 4: Queue View Artist N+1 Fix (issue #1)

**QueueManagementView.swift**:

1. Add `@State private var artistNameCache: [Int64: String] = [:]`
2. On `.onAppear`, call `DatabaseManager.shared.getAllArtistNamesById()` to populate cache
3. Pass `artistName: track.artistId.flatMap { artistNameCache[$0] }` to each `QueueTrackRow`
4. In `QueueTrackRow`: replace per-row DB read (lines 182-185) with the passed `artistName` string

---

## Phase 5: All Songs Progressive Loading

**LibraryViews.swift** — The All Songs `List` forces SwiftUI to diff all 50K track identities at once, even though cells are recycled.

### Fix: Progressive rendering in TrackListContentView (line 981)

- Add `@State private var displayLimit = 50`
- Render `List(Array(tracks.prefix(displayLimit)), id: \.stableId)` instead of the full `tracks` array
- Add a sentinel/invisible row at the bottom that triggers `displayLimit += 50` on `.onAppear`
- Reset `displayLimit = 50` via `.onChange(of: tracks.count)` (when sort changes or library refreshes, the passed array changes)

**Important**: The full `tracks` array stays as-is for:
- `playTrack(track, queue: tracks)` (line 1046) — play queue is the full sorted list
- `selectAll()` (line 852 in parent) — bulk selects from full list
- `bulkDelete/bulkAddToLiked` (lines 857, 867 in parent) — operates on full list

Only the List rendering is limited. This means no behavioral change for playback, bulk ops, or queue management — just faster initial rendering.

**Sort performance note**: The `sortedTracks` computed property (line 781) is O(n log n) ≈ 10-50ms for 50K tracks, which is fast. The bottleneck is SwiftUI diffing 50K identities, which progressive loading eliminates. No sort caching needed.

---

## Phase 6: CarPlay Optimization (issues #8, #9, #10)

**CarPlaySceneDelegate.swift** — Same functionality, but load progressively instead of all at once.

### Remove
- `var allTracks: [Track]` property — no longer hold entire library in memory permanently

### Add
- `private var artistNameCache: [Int64: String]` — built once at connect via single query
- `private let incompatibleFormats = ["ogg", "opus", "dsf", "dff"]`
- `private let maxArtworkItems = 50` — cap artwork loading per list
- `private let carPlayPageSize = 200` — tracks loaded per page
- `private var allSongsOffset = 0` — current pagination offset for All Songs
- `private var allSongsTotal = 0` — total track count

### Changes

**`didConnect`**: Build artist cache only. Don't load any tracks yet.

**All Songs tab** → Same flat list, but **paginated**:
- Load first 200 tracks from DB (using `LIMIT 200 OFFSET 0`)
- Add a "Load More..." CPListItem at the bottom
- When tapped, load next 200, rebuild template sections with accumulated items
- Artist names from cache (no per-track DB lookups)
- Artwork limited to first 50 items per page load

**Favorites tab** → Use `getFavoriteTracks(excludingFormats:)` DB query instead of filtering full library array. Same flat list.

**Browse tabs (Artists/Albums)** → Load tracks per-artist/album on navigation (DB query), not from in-memory array. Same navigation structure.

**Search** → Use existing `searchTracks(query:limit:)` DB function instead of in-memory filter on 50K tracks.

**All detail views** → Artist name from cache (`artistNameCache[id]`), artwork limited to first 50 items.

### New DB helper needed
Add `getTracksPaginated(limit:offset:excludingFormats:) -> [Track]` to DatabaseManager for CarPlay pagination.
Add `getTrackCount(excludingFormats:) -> Int` for total count.

---

## Phase 7: Playlist N+1 Batch Queries (issue #5)

**AppCoordinator.swift** — Replace 5 N+1 loops with batch `getTracksByStableIds()`:

| Location | Lines | Pattern |
|----------|-------|---------|
| `restorePlaylistsFromiCloud` (existing playlist sync) | ~449-454 | Batch fetch, check existence from Set |
| `restorePlaylistsFromiCloud` (new playlist create) | ~469-474 | Same pattern |
| `retryPlaylistRestoration` | ~565-569 | Same pattern |
| `syncPlaylistsToCloud` | ~771-777 | Same pattern |
| `updateWidgetPlaylists` | ~839-845 | Use `getTracksByStableIdsPreservingOrder` |

Each replaces N individual `getTrack(byStableId:)` calls with 1 batch query + Set lookup.

---

## Phase 8: CloudDownloadManager Optimization (issues #6, #7)

**CloudDownloadManager.swift** — Two changes:

### 7a: Optimize processQueryUpdate (issue #6)
Replace the loop over ALL query results (potentially 50K items) with direct resource value checks on only the tracked `downloadingFiles` set. This makes processing O(downloadingFiles.count) ≈ O(3) instead of O(50K).

### 7b: Add download concurrency limit (issue #7)
- Add `maxConcurrentDownloads = 3` and `pendingDownloads: [URL]` queue
- In `startDownload()`: if at capacity, queue the URL
- On download completion: `dequeueNextDownload()` to start next pending URL
- Call dequeue from all completion paths (processQueryUpdate, fallback monitor)

---

## Issue #3 (Queue Drag O(n))
No code change needed. The O(n) array manipulation is inherent to Swift arrays and the drag doesn't trigger explicit saves. The real perf improvement for the queue view comes from the artist cache fix in Phase 4.

---

## Breakage Risk Assessment

| Phase | Risk | Mitigation |
|-------|------|------------|
| 1 (DB helpers) | None — purely additive functions | N/A |
| 2 (originalQueue→[String]) | Medium — unshuffle does DB fetch; if tracks deleted between shuffle/unshuffle, they're dropped | Correct behavior (don't play deleted tracks). Error handling on DB fetch failure falls back gracefully. |
| 3 (Save cap 2000) | Low — users with >2000 queue lose some on restart | Acceptable tradeoff; 2000 is generous. The current playing track is always preserved. |
| 4 (Queue artist cache) | Very low — stale if artist renamed while queue open | Re-opening queue refreshes. Negligible edge case. |
| 5 (Progressive loading) | Low — full array still used for queue/bulk ops | Only List rendering is limited. `selectAll()`, `playTrack(queue:)`, and `bulkDelete` all use the full array. |
| 6 (CarPlay pagination) | Low — UX change (Load More button) | Same songs, same sort. Just paginated. Queue is set to the loaded page's tracks. |
| 7 (Playlist batch) | Very low — same results, fewer queries | GRDB handles large IN clauses. Playlists rarely exceed 1000 items. |
| 8 (Download cap) | Low — downloads are queued, not dropped | Pending downloads start as slots free up. Max 3 concurrent is standard practice. |

### Impact Assessment

| Phase | Memory Savings | Speed Improvement | Worth It? |
|-------|---------------|-------------------|-----------|
| 1 (DB helpers) | — | Enables other phases | Yes (required) |
| 2 (originalQueue) | ~10-15MB with 50K queue | Eliminates 50K-object copy on shuffle | Yes |
| 3 (Save cap + N+1) | Smaller UserDefaults | 50K→1 DB query on restore | Yes |
| 4 (Queue artist cache) | — | Eliminates N DB reads per scroll | Yes |
| 5 (Progressive loading) | — | SwiftUI diffs 50 vs 50K items on render | Yes (biggest UI impact) |
| 6 (CarPlay) | ~20-30MB (no allTracks) | Only 200 items created vs 50K | Yes |
| 7 (Playlist batch) | — | N→1 queries per playlist restore | Yes |
| 8 (Download concurrency) | — | Prevents OS throttling/timeouts | Yes |

---

## Verification
1. **Shuffle**: Toggle shuffle on/off, verify playback continues correctly and queue order restores
2. **State restore**: Kill app while playing, relaunch, verify queue + position restores
3. **Queue view**: Open queue with 1000+ tracks, scroll rapidly, verify no stuttering
4. **All Songs**: Open All Songs, verify tracks load progressively (first 50, then more on scroll). Change sort option, verify list updates correctly. Scroll to bottom, verify all tracks eventually load. Play a track and verify the full library is in the queue.
5. **CarPlay**: Test paginated All Songs, favorites, search, artist/album detail in simulator
6. **Playlists**: Re-sync from iCloud, verify all playlists restore with correct tracks
7. **Downloads**: Queue 5+ iCloud downloads, verify only 3 run concurrently

---

## Additional Findings From Code Audit (Not Yet Covered)

### User-Confirmed Scope Refinement

- **Include**: Original Phases 1-8 + high-priority additions below.
- **Include (medium, UI-lag only)**: defer heavy post-index passes (`verifyDatabaseRelationships`, orphan cleanup) to background idle/manual sync.
- **Exclude for now**: pure tuning items like DB title/name indexes.
- **Indexing UI updates**: coalesced refresh every ~2 seconds + one final refresh on indexing completion.
- **Artwork strategy**: dynamic visible-window cache with small prefetch window; aggressively evict off-screen images.
- **N+1 scope**: long-scrolling lists + search results (not mini-player/player header in this pass).
- **Playlist materialization**: replace remaining UI + CarPlay `getAllTracks()+first(where:)` / per-item fetch loops with ordered batch fetch.
- **CarPlay/library queue behavior**: use forward-only queue from selected song with **5,000 stable ID cap** (avoid full-library queue pressure).

### High Priority (Add before rollout)

1. **Indexing refresh storm (major UI/DB churn)**
   - `LibraryIndexer` posts `TrackFound` per processed file (`LibraryIndexer.swift` lines ~524, ~589).
   - `ContentView` refreshes full library on every `TrackFound` and every second while indexing (`ContentView.swift` lines ~138-154).
   - `refreshLibrary()` always calls `getAllTracks()` (`ContentView.swift` lines ~62-76).
   - **Impact**: repeated full-table reads and SwiftUI tree updates during indexing; scales poorly with 10K-20K+ tracks.
   - **Fix**: coalesce refreshes (e.g., debounce/throttle), stop full refresh on every `TrackFound`, keep one final full refresh when indexing ends.

2. **Unbounded artwork memory cache**
   - `ArtworkManager` uses unbounded `[String: UIImage]` memory cache (`ArtworkManager.swift` line ~18) with no count/cost limit.
   - **Impact**: memory growth as users browse large libraries, especially after long sessions.
   - **Fix**: replace with `NSCache` and set count/cost limits; clear aggressively on memory warning/background.

3. **N+1 artist DB reads still widespread outside Queue/CarPlay**
   - Per-row artist fetches exist in `TrackRowView`, search rows, playlist rows, album rows, mini player, etc. (`LibraryViews.swift`, `PlaylistViews.swift`, `AlbumViews.swift`, `PlayerViews.swift`).
   - **Impact**: frequent DB roundtrips while scrolling large lists.
   - **Fix**: extend artist-name cache approach beyond queue/carplay; pass resolved names to row views.

4. **Repeated O(n) filtering across album/artist/search screens**
   - Many screens compute `tracks.filter { ... }` repeatedly for each album/artist (`AlbumsScreen.getAlbumTracks`, `ArtistDetailScreen.artistTracks`, `SearchArtistRowView`, `SearchAlbumRowView`).
   - **Impact**: O(albums × tracks) / O(artists × tracks) behavior.
   - **Fix**: pre-group once (`[albumId: [Track]]`, `[artistId: [Track]]`) or query DB directly per destination screen.

5. **Playlist track materialization still O(n×m) in UI paths**
   - `PlaylistViews` and CarPlay playlist detail still use `getAllTracks()` + `first(where:)` or per-item `getTrack(byStableId:)`.
   - **Impact**: expensive for large libraries and large playlists.
   - **Fix**: use ordered batch fetch helper (`getTracksByStableIdsPreservingOrder`) everywhere playlist items are materialized.

### Medium Priority

6. **Post-index verification is heavier than needed**
   - `verifyDatabaseRelationships()` uses `contains` over arrays inside track loop (`AppCoordinator.swift` lines ~507-523), plus verbose per-track logs.
   - **Fix**: prebuild `Set` of valid IDs and log only aggregated counts.

7. **File cleanup scan is full-library I/O each indexing completion**
   - `checkForOrphanedFiles()` iterates all tracks and checks filesystem paths (`FileCleanupManager.swift` lines ~34-127).
   - **Fix**: run less frequently (manual/periodic), in background, and avoid verbose per-file logging.

8. **Artwork pre-caching during indexing adds large extra I/O**
   - `LibraryIndexer` calls `cacheArtwork(for:)` for each new track while indexing.
   - **Fix**: make pre-cache optional/throttled; prefer lazy on-demand artwork extraction.

9. **Missing DB indexes for title-based browse/search**
   - Existing indexes are mainly `track(album_id)` and `track(artist_id)`; title/name searches/sorts are frequent.
   - **Fix**: add indexes for `track(title)`, `artist(name)`, `album(title)`, and optionally `playlist(title)` after measuring query plans.

10. **CarPlay pagination behavior risk**
   - Planned pagination can accidentally queue only loaded page if not handled carefully.
   - **Fix (scoped)**: use forward-only queue from selected song with 5,000 stable ID cap to preserve "next songs" behavior while avoiding large queue pressure.

### Suggested Additional Phases

9. **Refresh Coalescing Phase**: throttle/debounce library refresh during indexing.
10. **Artwork Cache Bounding Phase**: bounded in-memory artwork cache + memory-pressure handling.
11. **Cross-Screen N+1 Cleanup Phase**: shared artist cache + row model enrichment.
12. **Grouped Data Phase**: pre-group tracks by artist/album in album/artist/search surfaces.
13. **Playlist Materialization Phase**: replace remaining `getAllTracks()+first(where:)` and per-item fetch loops with ordered batch fetches.
14. **Post-Index Efficiency Phase**: optimize verification/cleanup passes and reduce logging.
15. **Indexing/DB Index Phase**: **deferred** (out of current scope).
