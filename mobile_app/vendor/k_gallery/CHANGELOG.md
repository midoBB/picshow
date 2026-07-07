## 1.1.1

- **Fix**: Video and YouTube items no longer flash a **black screen while loading**. Swiping to a video previously revealed the raw (black) video texture / YouTube WebView until the first frame rendered. A loading spinner (`GalleryMediaLoader`) now covers the media until it is actually ready — the video controller paints its first frame (`VideoController.rect` becomes non-null) or the YouTube player reports `isReady`.
- **Improve**: YouTube **fullscreen** controls now match the inline media controls — the play/pause button and seekbar auto-hide after 3s of playback and toggle on tap, and the buffering spinner shows whenever the player is buffering.
- **Example**: Added a second YouTube item to the demo gallery to exercise the fullscreen auto-hide controls.

## 1.1.0

- **New**: `KGallery.show(context, contentList: ..., initialIndex: ...)` — opens the gallery on a **non-opaque route** so the screen behind stays visible through the background fade during swipe-to-dismiss. Returns the last-viewed index. This is now the recommended way to present the gallery; pushing `KGallery` on a normal opaque route (e.g. `MaterialPageRoute`) makes the swipe-down fade reveal only black. Mirrors the `showDialog`/`showModalBottomSheet` convention. The `KGallery` widget constructor is unchanged.
- **New**: `cacheManager` and `memCacheWidth` parameters on `KGallery` / `KGallery.show(...)`, forwarded to the underlying `CachedNetworkImage`. Pass your own `BaseCacheManager` (e.g. `CacheManager(Config(...))`) to share a disk cache with the rest of your app or control its policy, and `memCacheWidth` to cap the in-memory bitmap width of full-screen images. `BaseCacheManager`, `CacheManager`, `Config`, and `DefaultCacheManager` are now re-exported from `package:k_gallery`.
- **New**: Inline **base64 image** support — pass a data URI (`data:image/png;base64,...`) in the existing `url` or `thumbnailUrl` fields and it renders everywhere an image appears (full-screen viewer, thumbnail strip, audio/video posters). No network request is made; no `GalleryItem` change is required. Detection is automatic on the `;base64,` marker, and decoded bytes are kept in a bounded LRU cache so repeated rebuilds (zoom, thumbnail scroll) neither re-decode nor miss Flutter's image cache.
- **Improve**: Max pinch-zoom raised from 3.0× to 8.0×.
- **Fix**: Drag-to-dismiss no longer fires while an image is zoomed in — single-finger drags pan the zoomed image instead, and only fall through to vertical dismiss / horizontal page navigation at 1.0× scale.
- **Fix**: Eliminated a sudden transform jump mid-pinch. Toggling `InteractiveViewer.panEnabled` during a live gesture rebuilt its gesture recognisers and reset pointer tracking; the flip is now deferred to the end of the gesture.
- **Fix**: Double-tap zoom now centers on the tapped point instead of the image center.
- **Polish**: Swipe-to-dismiss now uses an Apple Photos–style fly-away animation (the image flies off-screen before the route pops) with a spring snap-back when released below the threshold.

## 1.0.3

- **Change**: Migrated image rendering from `extended_image` to `cached_network_image`. Full-size images and thumbnails now share a disk-backed cache, which dramatically reduces repeat-network fetches when the same item is revisited and shrinks the dependency footprint.
- **Perf**: New `DeferredInit` widget delays expensive media initialization (`media_kit` `Player` setup, YouTube WebView, audio playback) by 150 ms inside the `PageView`. Pages scrolled past quickly never instantiate a player, eliminating wasted network calls and AVAudioSession churn during fast swipes.
- **Refactor**: Image viewing was split into focused widgets — `GalleryImageItem`, `ZoomableImage`, `DismissibleDragArea`, and `ZoomAwarePageView`. Zoom is now backed by Flutter's `InteractiveViewer` (with a `ValueNotifier<double>` exposing the current scale), and the parent `PageView` automatically disables horizontal swipe while zoomed.
- **Improve**: Vertical drag-to-dismiss is now a dedicated `DismissibleDragArea` recognizer that reports normalized drag progress (0.0–1.0) so the backdrop can fade in sync with the gesture, with a velocity-based dismiss in addition to the existing distance threshold.
- **Deps**: Removed `extended_image`. Added `cached_network_image: ^3.4.1`.

## 1.0.2

- **New**: `GalleryItemType.youtube` — play any YouTube URL (`youtu.be/...`, `youtube.com/watch?v=...`, `/shorts/...`, `/embed/...`) directly in the gallery with the same play/pause button, buffering indicator, and themed seekbar as regular video items.
- **New**: YouTube fullscreen — tap the `⤢` button to open a landscape fullscreen route with a position/duration timer (`00:42 / 10:23`), seekbar (colors from `GalleryTheme`), and exit button — matching the media_kit video fullscreen layout.
- **New**: Seekbar shown above the thumbnail strip for video, audio, and YouTube items while controls are visible.
- **Fix (iOS)**: Video playback stopped ~1 s after swiping past an adjacent audio item. Each item now lazily creates and disposes its `media_kit` `Player` — only one `Player` is alive at a time, eliminating AVAudioSession conflicts.
- **Fix**: YouTube fullscreen playback — video now auto-plays correctly when entering and exiting fullscreen. Root cause: a stale `isReady` flag on the shared `YoutubePlayerController` caused the seek-to-resume command to fire before the new WebView's IFrame API was ready; fixed by resetting `isReady` before each WebView swap.
- **Perf**: Narrowed `BlocBuilder.buildWhen` on the page view so it rebuilds only when the items list changes — previously, every UI tap, swipe gesture, or text-panel drag triggered a full page-view rebuild.
- **Perf**: YouTube play/pause controls now update via a scoped `AnimatedBuilder` instead of full-widget `setState` on every controller tick.
- **Deps**: `flutter_bloc` → ^9.1.1, `freezed_annotation` → ^3.1.0, `extended_image` → ^10.0.1, `json_annotation` → ^4.11.0.

## 1.0.1

- Documentation: Updated README with demo video and screenshots for better project visibility.
- Fix: Use absolute URLs for documentation assets to ensure cross-platform compatibility.

## 1.0.0

### Features
- Full-screen image viewing with pinch-to-zoom and double-tap zoom
- Video playback with seekbar controls (powered by MediaKit)
- Audio playback with album art display
- Animated thumbnail strip with haptic feedback
- Swipe-to-dismiss with dynamic background fade
- Draggable text panel for title/description overlays
- Adaptive layout for phones and tablets
- Connectivity-aware media playback with user feedback
- Customizable progress/placeholder widgets
- Action menu builder for custom toolbar actions
- Hero animation support for smooth transitions
- Configurable zoom, haptics, and swipe-to-dismiss
