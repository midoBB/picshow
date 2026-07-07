import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k_gallery/k_gallery.dart';
import 'package:k_gallery/src/utils/image_source.dart';

/// A valid 1×1 PNG encoded as an inline base64 data URI.
const String _validBase64Image =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR42mPQO1MIAAKXAWyCXhvQAAAAAElFTkSuQmCC';

/// Same payload but with whitespace/newlines, as some encoders emit.
const String _whitespaceBase64Image =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1Pe\n'
    '  AAAADElEQVR42mPQO1MIAAKXAWyCXhvQAAAAAElFTkSuQmCC  ';

/// Has the data-URI marker but the payload is not decodable base64.
const String _invalidBase64Image = 'data:image/png;base64,@@@not-base64@@@';

const String _networkImage = 'https://example.com/image1.jpg';

void main() {
  group('isBase64DataUri', () {
    test('detects base64 data URIs and rejects network URLs', () {
      expect(isBase64DataUri(_validBase64Image), isTrue);
      expect(isBase64DataUri(_invalidBase64Image), isTrue); // marker present
      expect(isBase64DataUri(_networkImage), isFalse);
      expect(isBase64DataUri(''), isFalse);
      expect(isBase64DataUri('data:,plaintext'), isFalse); // no ;base64,
    });
  });

  group('decodeBase64DataUri', () {
    test('decodes a valid payload to non-empty bytes', () {
      final bytes = decodeBase64DataUri(_validBase64Image);
      expect(bytes, isNotNull);
      expect(bytes!.isNotEmpty, isTrue);
    });

    test('tolerates whitespace/newlines in the payload', () {
      expect(decodeBase64DataUri(_whitespaceBase64Image), isNotNull);
    });

    test('returns null (never throws) for malformed base64', () {
      expect(decodeBase64DataUri(_invalidBase64Image), isNull);
    });

    test('returns null for a non-data-URI string', () {
      expect(decodeBase64DataUri(_networkImage), isNull);
    });

    test('returns the same cached instance on repeated calls', () {
      final first = decodeBase64DataUri(_validBase64Image);
      final second = decodeBase64DataUri(_validBase64Image);
      expect(identical(first, second), isTrue);
    });
  });

  group('galleryImage widget', () {
    testWidgets('base64 source renders Image.memory, not CachedNetworkImage', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: galleryImage(
            source: _validBase64Image,
            fit: BoxFit.contain,
            errorWidget: (_, __, ___) => const Icon(Icons.broken_image),
          ),
        ),
      );

      expect(find.byType(CachedNetworkImage), findsNothing);
      expect(find.byType(Icon), findsNothing);
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<MemoryImage>());
      expect(tester.takeException(), isNull);
    });

    testWidgets('network source renders CachedNetworkImage', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: galleryImage(
            source: _networkImage,
            fit: BoxFit.contain,
            errorWidget: (_, __, ___) => const Icon(Icons.broken_image),
          ),
        ),
      );

      expect(find.byType(CachedNetworkImage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('malformed base64 falls back to the error widget', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: galleryImage(
            source: _invalidBase64Image,
            fit: BoxFit.contain,
            errorWidget: (_, __, ___) => const Icon(Icons.broken_image),
          ),
        ),
      );

      expect(find.byIcon(Icons.broken_image), findsOneWidget);
      expect(find.byType(CachedNetworkImage), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('KGallery', () {
    testWidgets('displays the correct initial image', (tester) async {
      final contentList = [
        const GalleryItem(
          url: 'https://example.com/image1.jpg',
          title: 'Image 1',
          description: 'Description 1',
        ),
        const GalleryItem(
          url: 'https://example.com/image2.jpg',
          title: 'Image 2',
          description: 'Description 2',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KGallery(contentList: contentList, initialIndex: 0),
          ),
        ),
      );

      expect(find.text('Image 1'), findsOneWidget);
      expect(find.text('Description 1'), findsOneWidget);
      expect(find.text('Image 2'), findsNothing);
    });

    testWidgets('throws assertion error on empty list', (tester) async {
      expect(
        () => KGallery(contentList: const [], initialIndex: 0),
        throwsAssertionError,
      );
    });

    testWidgets('renders a base64 image item without the broken-image widget', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KGallery(
              contentList: const [
                GalleryItem(url: _validBase64Image, title: 'Local base64'),
              ],
              initialIndex: 0,
            ),
          ),
        ),
      );

      expect(find.text('Local base64'), findsOneWidget);
      expect(find.byIcon(Icons.broken_image), findsNothing);
      // The base64 item paints via Image.memory, never CachedNetworkImage.
      expect(
        tester.widgetList<Image>(find.byType(Image)).any(
          (w) => w.image is MemoryImage,
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('handles a mix of base64 and network items', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KGallery(
              contentList: const [
                GalleryItem(url: _validBase64Image, title: 'Local base64'),
                GalleryItem(url: _networkImage, title: 'Remote'),
              ],
              initialIndex: 0,
            ),
          ),
        ),
      );

      // Current page is the base64 item; the network item is also referenced
      // by the thumbnail strip without throwing.
      expect(find.text('Local base64'), findsOneWidget);
      expect(find.byIcon(Icons.broken_image), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
