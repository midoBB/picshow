import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import '../models/gallery_item.dart';

part 'gallery_bloc.freezed.dart';

/// Manages the state for the [KGallery] widget.
///
/// Handles index changes, UI visibility toggling,
/// text panel height, and slide-to-dismiss state.
class GalleryBloc extends Bloc<GalleryEvent, GalleryState> {
  GalleryBloc({List<GalleryItem> initialItems = const [], int initialIndex = 0})
    : super(
        GalleryState(
          items: initialItems,
          currentIndex: initialIndex,
          isInitialized: initialItems.isNotEmpty,
        ),
      ) {
    on<GalleryInitialize>((event, emit) {
      emit(
        state.copyWith(
          items: event.items,
          currentIndex: event.initialIndex,
          isInitialized: true,
        ),
      );
    });

    on<GalleryIndexChanged>((event, emit) {
      if (state.currentIndex != event.index) {
        emit(
          state.copyWith(
            currentIndex: event.index,
            textPanelHeight: GalleryState.minTextPanelHeight,
          ),
        );
      }
    });

    on<GalleryTextPanelHeightChanged>((event, emit) {
      emit(state.copyWith(textPanelHeight: event.height));
    });

    on<GalleryToggleUI>((event, emit) {
      emit(state.copyWith(isUIVisible: event.isVisible ?? !state.isUIVisible));
    });

    on<GallerySetSliding>((event, emit) {
      emit(state.copyWith(isSliding: event.isSliding));
    });
  }
}

/// Immutable state for the gallery viewer.
@freezed
class GalleryState with _$GalleryState {
  const GalleryState._();

  /// Minimum height for the text panel overlay.
  static const double minTextPanelHeight = 70.0;

  const factory GalleryState({
    /// The list of gallery items being displayed.
    @Default([]) List<GalleryItem> items,
    /// Index of the currently visible item.
    @Default(0) int currentIndex,
    /// Whether the top bar and thumbnail strip are visible.
    @Default(true) bool isUIVisible,
    /// Whether the gallery has been initialized with items.
    @Default(false) bool isInitialized,
    /// Whether the user is actively sliding/dismissing.
    @Default(false) bool isSliding,
    /// Current height of the draggable text panel.
    @Default(GalleryState.minTextPanelHeight) double textPanelHeight,
  }) = _GalleryState;
}

/// Base class for all gallery events.
sealed class GalleryEvent {}

/// Initializes the gallery with a list of items and starting index.
class GalleryInitialize extends GalleryEvent {
  /// The items to display in the gallery.
  final List<GalleryItem> items;

  /// The index to start displaying from.
  final int initialIndex;

  GalleryInitialize({required this.items, required this.initialIndex});
}

/// Emitted when the currently displayed item changes.
class GalleryIndexChanged extends GalleryEvent {
  /// The new current index.
  final int index;

  GalleryIndexChanged(this.index);
}

/// Toggles or sets UI visibility (top bar, thumbnails).
class GalleryToggleUI extends GalleryEvent {
  /// If provided, sets visibility explicitly. If null, toggles.
  final bool? isVisible;

  GalleryToggleUI({this.isVisible});
}

/// Sets whether the user is actively sliding to dismiss.
class GallerySetSliding extends GalleryEvent {
  /// Whether the slide gesture is active.
  final bool isSliding;

  GallerySetSliding(this.isSliding);
}

/// Updates the height of the draggable text description panel.
class GalleryTextPanelHeightChanged extends GalleryEvent {
  /// The new panel height.
  final double height;

  GalleryTextPanelHeightChanged(this.height);
}
