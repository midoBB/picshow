# kGallery Flutter Package — Project Reference

**Package**: `k_gallery` v1.0.1  
**Type**: Flutter package (pub.dev publishable)  
**Purpose**: Telegram-style media gallery viewer (images, video, audio) with pinch-zoom, thumbnail strip, swipe-dismiss, text overlay  
**Repo**: https://github.com/vishalbaps/kGallery  
**Requirements**: Flutter >=3.10.0, Dart SDK >=3.0.0 <4.0.0

---

## Directory Structure

```
kGallery/
├── lib/
│   ├── k_gallery.dart                          # Public exports: KGallery, GalleryItem, GalleryTheme
│   └── src/
│       ├── bloc/
│       │   ├── gallery_bloc.dart               # BLoC: events, state, handlers
│       │   └── gallery_bloc.freezed.dart       # Generated: immutable state + copyWith
│       ├── models/
│       │   ├── gallery_item.dart               # GalleryItem model + GalleryItemType enum
│       │   ├── gallery_item.g.dart             # Generated: JSON serialization
│       │   └── gallery_theme.dart              # GalleryTheme customization class
│       └── widgets/
│           ├── k_gallery_widget.dart           # KGallery main widget (entry point)
│           ├── gallery_image_viewer.dart       # Gesture + zoom + swipe-dismiss viewer
│           ├── gallery_thumbnail_strip.dart    # Bottom thumbnail scrollable strip
│           └── gallery_media_item_widget.dart  # Video/audio playback widget (media_kit)
├── example/
│   └── lib/
│       ├── main.dart                           # go_router setup, single grid route
│       └── gallery_demo_screen.dart            # DemoGalleryScreen (100 items); opens gallery via KGallery.show(...)
├── test/
│   └── k_gallery_test.dart                     # 2 tests: initial display, assertion on empty list
├── pubspec.yaml
├── CHANGELOG.md
├── README.md
└── analysis_options.yaml
```

---

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| `flutter_bloc` | ^9.1.1 | BLoC state management |
| `freezed_annotation` | ^3.1.0 | Immutable model annotations |
| `extended_image` | ^10.0.1 | Image with pinch-zoom + gesture support |
| `json_annotation` | ^4.11.0 | JSON serialization annotations |
| `shimmer` | ^3.0.0 | Loading shimmer for thumbnails |
| `media_kit` | ^1.2.6 | Video/audio playback |
| `media_kit_video` | ^2.0.1 | Video widget |
| `media_kit_libs_video` | ^1.0.7 | Media codecs |
| `connectivity_plus` | ^7.1.1 | Internet connectivity check |

**Dev**: `build_runner`, `freezed`, `json_serializable`, `flutter_lints`

---

## Public API (`lib/k_gallery.dart`)

### `KGallery` (main widget)
- **Required**: `List<GalleryItem> contentList`, `int initialIndex`
- **Optional**: `progressWidget`, `thumbProgressWidget`, `enableZoom` (true), `enableSwipeToDismiss` (true), `enableHapticFeedback` (true), `leading`, `title`, `noInternetMessage`, `onIndexChanged(int)`, `onClose(int)`, `theme`, `actionMenuBuilder(BuildContext, int, List<GalleryItem>)`, `cacheManager` (`BaseCacheManager?`), `memCacheWidth` (`int?`)
- **Network image caching**: `cacheManager` is forwarded to `CachedNetworkImage` for all network images (full-screen viewer, thumbnail strip, audio artwork). `memCacheWidth` caps the in-memory bitmap width for full-screen images only; thumbnails use a fixed 320px decode cap (`cacheWidth` for base64, `memCacheWidth` for network). `BaseCacheManager`/`CacheManager`/`Config`/`DefaultCacheManager` are re-exported from `lib/k_gallery.dart`. Plumbing: `KGallery` → `GalleryImageViewer` → `GalleryImageItem`/`GalleryAudioItem` and `KGallery` → `GalleryThumbnailStrip`, all bottoming out in `galleryImage()` in `lib/src/utils/image_source.dart`.
- **Static**: `KGallery.ensureInitialized()` — must call before `runApp()` for media_kit
- **Static**: `KGallery.show(context, {contentList, initialIndex, ...})` → `Future<int?>` — recommended entry point. Pushes a **non-opaque** `PageRouteBuilder` (`opaque: false`, transparent barrier, fade transition) wrapping `KGallery`, so the screen behind stays visible through the background fade during swipe-to-dismiss. Mirrors the constructor's params; returns the last-viewed index. Does NOT inject `onClose` (the default `Navigator.maybePop(currentIndex)` path returns the index; injecting one would double-pop via `PopScope`).

### `GalleryItem`
- Fields: `String url` (required), `GalleryItemType type` (default: image), `String? thumbnailUrl`, `String? title`, `String? description`
- JSON: `fromJson()` / `toJson()`

### `GalleryItemType` (enum)
- `image`, `video`, `audio`

### `GalleryTheme`
- Fields: `backgroundColor` (black), `appBarColor` (black 50%), `seekbarActiveColor` (white), `seekbarInactiveColor` (white30), `mobileThumbnailHeight` (90), `tabletThumbnailHeight` (110), `titleTextStyle?`, `descriptionTextStyle?`, `counterTextStyle?`, `noInternetMessage`
- Factory: `GalleryTheme.dark()`

---

## BLoC Architecture

### `GalleryState` (Freezed)
```dart
items: List<GalleryItem>
currentIndex: int            // default 0
isUIVisible: bool            // default true
isInitialized: bool          // default false
isSliding: bool              // default false
textPanelHeight: double      // default 70.0
static const minTextPanelHeight = 70.0
```

### Events (sealed)
- `GalleryInitialize(items, initialIndex)`
- `GalleryIndexChanged(index)` → resets textPanelHeight to min
- `GalleryToggleUI(isVisible?)` → flip or set isUIVisible
- `GallerySetSliding(isSliding)` → track gesture state
- `GalleryTextPanelHeightChanged(height)` → draggable panel height

---

## Widget Details

### `GalleryImageViewer`
- Renders `ExtendedImage.network` for images (zoom: 0.9–3.0x)
- Renders `GalleryMediaItemWidget` for video/audio
- Single tap → toggle UI (250ms delay)
- Double tap → zoom 1.0x ↔ 2.5x (animated)
- Pinch → multi-pointer zoom, hides UI
- Swipe down → dy > 150px + time < 400ms + dx < 50 → dismiss

### `GalleryThumbnailStrip`
- Horizontal ListView, auto-scrolls to current item
- Mobile: 90px strip, 48px unselected, 68px selected
- Tablet (≥600dp): 110px strip, 60px unselected, 86px selected
- Animated size change on selection (white border, easeOutBack)
- Play/audio icons overlay on video/audio thumbnails
- Slides out via AnimatedPositioned: `bottom: -(height+padding+20)` when hidden

### `GalleryMediaItemWidget`
- Creates `media_kit` Player, opens URL (no autoplay)
- Remote URLs: checks connectivity before play → shows SnackBar if offline
- Auto-hides UI after 3s of playback
- Audio mode: shows thumbnailUrl or audiotrack icon
- Video mode: `Video` widget with `NoVideoControls`
- Center play/pause button with buffering indicator

### `KGallery` internal stack (bottom to top)
1. `GalleryImageViewer` (full screen)
2. `_GalleryOverlayLayer` (seekbar + text panel) — above gallery
3. `_GalleryTopBar` (app bar with blur) — positioned top
4. `GalleryThumbnailStrip` — positioned bottom

---

## Responsive Breakpoint
- `MediaQuery.shortestSide >= 600` → tablet mode
- Top bar height: mobile 56px, tablet 80px
- Thumbnail height: mobile 90px, tablet 110px

---

## Example App
- 100 items: item[0] = video (Big Buck Bunny), item[1] = audio (MP3), items[2-99] = loremflickr images
- Grid: 6 cols (≥800dp), 5 cols (≥600dp), 3 cols (phone)
- Navigation: go_router with a single `/k_gallery_demo` grid route; tapping a grid item opens the gallery via `KGallery.show(...)` (imperative transparent route — no separate detail route/widget)
- Hero animations between grid thumbnails and gallery

---

## Code Generation
Run to regenerate: `dart run build_runner build`  
Generated files: `gallery_bloc.freezed.dart`, `gallery_item.g.dart`

When adding new state fields → edit `gallery_bloc.dart` and re-run build_runner.  
When adding new media types → update `GalleryItemType` enum + `gallery_item.g.dart` + rendering logic in `GalleryMediaItemWidget`.
