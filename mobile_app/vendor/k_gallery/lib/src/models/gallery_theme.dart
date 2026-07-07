import 'package:flutter/material.dart';

/// Defines the visual appearance of the [KGallery] widget.
///
/// Use this class to customize colors, text styles, and layout dimensions
/// to match your app's design system.
class GalleryTheme {
  /// The background color of the gallery viewer.
  /// Defaults to [Colors.black].
  final Color backgroundColor;

  /// The background color of the top bar and thumbnail strip.
  /// Defaults to black with 50% opacity.
  final Color appBarColor;

  /// The message shown when a network error occurs (e.g., no internet).
  final String noInternetMessage;

  /// The color of the active seekbar.
  /// Defaults to [Colors.white].
  final Color seekbarActiveColor;

  /// The color of the inactive seekbar.
  /// Defaults to [Colors.white30].
  final Color seekbarInactiveColor;

  /// The text style for titles in the description panel.
  final TextStyle? titleTextStyle;

  /// The text style for descriptions in the description panel.
  final TextStyle? descriptionTextStyle;

  /// The text style for the counter (e.g., "1 / 5") in the top bar.
  final TextStyle? counterTextStyle;

  /// The height of the thumbnail strip on mobile devices.
  /// Defaults to 90.
  final double mobileThumbnailHeight;

  /// The height of the thumbnail strip on tablet devices.
  /// Defaults to 110.
  final double tabletThumbnailHeight;

  /// Creates a [GalleryTheme].
  const GalleryTheme({
    this.backgroundColor = Colors.black,
    this.appBarColor = const Color(0x80000000),
    this.noInternetMessage = 'No internet connection. Please check your network.',
    this.seekbarActiveColor = Colors.white,
    this.seekbarInactiveColor = Colors.white30,
    this.titleTextStyle,
    this.descriptionTextStyle,
    this.counterTextStyle,
    this.mobileThumbnailHeight = 90,
    this.tabletThumbnailHeight = 110,
  });

  /// Default dark theme for the gallery.
  factory GalleryTheme.dark() => const GalleryTheme();
}
