import 'package:flutter_test/flutter_test.dart';
import 'package:img_syncer/files_tree.dart';

String pathOf(String path) => path;

void main() {
  const items = [
    '2026/11/05/IMG_0001.jpg',
    '2026/11/05/IMG_0002.jpg',
    '2026/11/04/IMG_0003.jpg',
    '2025/12/31/IMG_0004.jpg',
    'manual/video/VID_0001.mp4',
    'manual/image/IMG_0005.jpg',
    'manual/image/live_abc/VID_0002.mp4',
    'root.jpg',
  ];

  test('root lists folders and root files', () {
    final view = folderView<String>(items: items, pathOf: pathOf);
    expect(
      view.folders.map((f) => f.name).toList(),
      ['manual', '2026', '2025'],
    );
    expect(view.files, ['root.jpg']);
  });

  test('folder file counts are recursive', () {
    final view = folderView<String>(items: items, pathOf: pathOf);
    final counts = {
      for (final f in view.folders) f.name: f.fileCount,
    };
    expect(counts['2026'], 3);
    expect(counts['2025'], 1);
    expect(counts['manual'], 3);
  });

  test('drilling into a date folder', () {
    final view = folderView<String>(
      items: items,
      pathOf: pathOf,
      prefix: ['2026', '11'],
    );
    expect(
      view.folders.map((f) => f.name).toList(),
      ['05', '04'],
    );
    expect(view.files, isEmpty);
  });

  test('leaf folder lists files newest name first', () {
    final view = folderView<String>(
      items: items,
      pathOf: pathOf,
      prefix: ['2026', '11', '05'],
    );
    expect(view.folders, isEmpty);
    expect(
      view.files,
      ['2026/11/05/IMG_0002.jpg', '2026/11/05/IMG_0001.jpg'],
    );
  });

  test('manual folder keeps video/image/live split', () {
    final view = folderView<String>(
      items: items,
      pathOf: pathOf,
      prefix: ['manual'],
    );
    expect(
      view.folders.map((f) => f.name).toList(),
      ['video', 'image'],
    );
    final image = folderView<String>(
      items: items,
      pathOf: pathOf,
      prefix: ['manual', 'image'],
    );
    expect(
      image.folders.map((f) => f.name).toList(),
      ['live_abc'],
    );
    expect(image.files, ['manual/image/IMG_0005.jpg']);
  });

  test('leading slashes and backslashes are normalized', () {
    final view = folderView<String>(
      items: const ['/2026/11/05/IMG_0001.jpg', '2026\\11\\05\\IMG_0002.jpg'],
      pathOf: pathOf,
      prefix: ['2026', '11', '05'],
    );
    expect(view.files.length, 2);
  });

  test('empty list and unknown prefix yield empty view', () {
    expect(
      folderView<String>(items: const [], pathOf: pathOf).files,
      isEmpty,
    );
    final view = folderView<String>(
      items: items,
      pathOf: pathOf,
      prefix: ['nope'],
    );
    expect(view.folders, isEmpty);
    expect(view.files, isEmpty);
  });
}
