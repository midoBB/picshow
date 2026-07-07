// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'gallery_bloc.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$GalleryState {
  /// The list of gallery items being displayed.
  List<GalleryItem> get items => throw _privateConstructorUsedError;

  /// Index of the currently visible item.
  int get currentIndex => throw _privateConstructorUsedError;

  /// Whether the top bar and thumbnail strip are visible.
  bool get isUIVisible => throw _privateConstructorUsedError;

  /// Whether the gallery has been initialized with items.
  bool get isInitialized => throw _privateConstructorUsedError;

  /// Whether the user is actively sliding/dismissing.
  bool get isSliding => throw _privateConstructorUsedError;

  /// Current height of the draggable text panel.
  double get textPanelHeight => throw _privateConstructorUsedError;

  /// Create a copy of GalleryState
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $GalleryStateCopyWith<GalleryState> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $GalleryStateCopyWith<$Res> {
  factory $GalleryStateCopyWith(
          GalleryState value, $Res Function(GalleryState) then) =
      _$GalleryStateCopyWithImpl<$Res, GalleryState>;
  @useResult
  $Res call(
      {List<GalleryItem> items,
      int currentIndex,
      bool isUIVisible,
      bool isInitialized,
      bool isSliding,
      double textPanelHeight});
}

/// @nodoc
class _$GalleryStateCopyWithImpl<$Res, $Val extends GalleryState>
    implements $GalleryStateCopyWith<$Res> {
  _$GalleryStateCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of GalleryState
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? items = null,
    Object? currentIndex = null,
    Object? isUIVisible = null,
    Object? isInitialized = null,
    Object? isSliding = null,
    Object? textPanelHeight = null,
  }) {
    return _then(_value.copyWith(
      items: null == items
          ? _value.items
          : items // ignore: cast_nullable_to_non_nullable
              as List<GalleryItem>,
      currentIndex: null == currentIndex
          ? _value.currentIndex
          : currentIndex // ignore: cast_nullable_to_non_nullable
              as int,
      isUIVisible: null == isUIVisible
          ? _value.isUIVisible
          : isUIVisible // ignore: cast_nullable_to_non_nullable
              as bool,
      isInitialized: null == isInitialized
          ? _value.isInitialized
          : isInitialized // ignore: cast_nullable_to_non_nullable
              as bool,
      isSliding: null == isSliding
          ? _value.isSliding
          : isSliding // ignore: cast_nullable_to_non_nullable
              as bool,
      textPanelHeight: null == textPanelHeight
          ? _value.textPanelHeight
          : textPanelHeight // ignore: cast_nullable_to_non_nullable
              as double,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$GalleryStateImplCopyWith<$Res>
    implements $GalleryStateCopyWith<$Res> {
  factory _$$GalleryStateImplCopyWith(
          _$GalleryStateImpl value, $Res Function(_$GalleryStateImpl) then) =
      __$$GalleryStateImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {List<GalleryItem> items,
      int currentIndex,
      bool isUIVisible,
      bool isInitialized,
      bool isSliding,
      double textPanelHeight});
}

/// @nodoc
class __$$GalleryStateImplCopyWithImpl<$Res>
    extends _$GalleryStateCopyWithImpl<$Res, _$GalleryStateImpl>
    implements _$$GalleryStateImplCopyWith<$Res> {
  __$$GalleryStateImplCopyWithImpl(
      _$GalleryStateImpl _value, $Res Function(_$GalleryStateImpl) _then)
      : super(_value, _then);

  /// Create a copy of GalleryState
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? items = null,
    Object? currentIndex = null,
    Object? isUIVisible = null,
    Object? isInitialized = null,
    Object? isSliding = null,
    Object? textPanelHeight = null,
  }) {
    return _then(_$GalleryStateImpl(
      items: null == items
          ? _value._items
          : items // ignore: cast_nullable_to_non_nullable
              as List<GalleryItem>,
      currentIndex: null == currentIndex
          ? _value.currentIndex
          : currentIndex // ignore: cast_nullable_to_non_nullable
              as int,
      isUIVisible: null == isUIVisible
          ? _value.isUIVisible
          : isUIVisible // ignore: cast_nullable_to_non_nullable
              as bool,
      isInitialized: null == isInitialized
          ? _value.isInitialized
          : isInitialized // ignore: cast_nullable_to_non_nullable
              as bool,
      isSliding: null == isSliding
          ? _value.isSliding
          : isSliding // ignore: cast_nullable_to_non_nullable
              as bool,
      textPanelHeight: null == textPanelHeight
          ? _value.textPanelHeight
          : textPanelHeight // ignore: cast_nullable_to_non_nullable
              as double,
    ));
  }
}

/// @nodoc

class _$GalleryStateImpl extends _GalleryState {
  const _$GalleryStateImpl(
      {final List<GalleryItem> items = const [],
      this.currentIndex = 0,
      this.isUIVisible = true,
      this.isInitialized = false,
      this.isSliding = false,
      this.textPanelHeight = GalleryState.minTextPanelHeight})
      : _items = items,
        super._();

  /// The list of gallery items being displayed.
  final List<GalleryItem> _items;

  /// The list of gallery items being displayed.
  @override
  @JsonKey()
  List<GalleryItem> get items {
    if (_items is EqualUnmodifiableListView) return _items;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_items);
  }

  /// Index of the currently visible item.
  @override
  @JsonKey()
  final int currentIndex;

  /// Whether the top bar and thumbnail strip are visible.
  @override
  @JsonKey()
  final bool isUIVisible;

  /// Whether the gallery has been initialized with items.
  @override
  @JsonKey()
  final bool isInitialized;

  /// Whether the user is actively sliding/dismissing.
  @override
  @JsonKey()
  final bool isSliding;

  /// Current height of the draggable text panel.
  @override
  @JsonKey()
  final double textPanelHeight;

  @override
  String toString() {
    return 'GalleryState(items: $items, currentIndex: $currentIndex, isUIVisible: $isUIVisible, isInitialized: $isInitialized, isSliding: $isSliding, textPanelHeight: $textPanelHeight)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$GalleryStateImpl &&
            const DeepCollectionEquality().equals(other._items, _items) &&
            (identical(other.currentIndex, currentIndex) ||
                other.currentIndex == currentIndex) &&
            (identical(other.isUIVisible, isUIVisible) ||
                other.isUIVisible == isUIVisible) &&
            (identical(other.isInitialized, isInitialized) ||
                other.isInitialized == isInitialized) &&
            (identical(other.isSliding, isSliding) ||
                other.isSliding == isSliding) &&
            (identical(other.textPanelHeight, textPanelHeight) ||
                other.textPanelHeight == textPanelHeight));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      const DeepCollectionEquality().hash(_items),
      currentIndex,
      isUIVisible,
      isInitialized,
      isSliding,
      textPanelHeight);

  /// Create a copy of GalleryState
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$GalleryStateImplCopyWith<_$GalleryStateImpl> get copyWith =>
      __$$GalleryStateImplCopyWithImpl<_$GalleryStateImpl>(this, _$identity);
}

abstract class _GalleryState extends GalleryState {
  const factory _GalleryState(
      {final List<GalleryItem> items,
      final int currentIndex,
      final bool isUIVisible,
      final bool isInitialized,
      final bool isSliding,
      final double textPanelHeight}) = _$GalleryStateImpl;
  const _GalleryState._() : super._();

  /// The list of gallery items being displayed.
  @override
  List<GalleryItem> get items;

  /// Index of the currently visible item.
  @override
  int get currentIndex;

  /// Whether the top bar and thumbnail strip are visible.
  @override
  bool get isUIVisible;

  /// Whether the gallery has been initialized with items.
  @override
  bool get isInitialized;

  /// Whether the user is actively sliding/dismissing.
  @override
  bool get isSliding;

  /// Current height of the draggable text panel.
  @override
  double get textPanelHeight;

  /// Create a copy of GalleryState
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$GalleryStateImplCopyWith<_$GalleryStateImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
