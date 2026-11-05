/// Pure folder-tree logic for the Files tab: build one level of a
/// remote-drive folder tree from flat server-side paths.
///
/// No Flutter imports, so this is unit-testable without a widget binding.
/// Paths are the server-side relative paths used by [RemoteImage.path]
/// (date folders for auto sync, `<manual>/video|image/` for manual
/// uploads). Only files the server reports (synced photos/videos) appear;
/// empty folders and non-media files on the drive are not listed.

/// Normalize a server-side path to '/'-separated segments without a
/// leading slash.
String normalizeRemotePath(String raw) {
  var path = raw.replaceAll('\\', '/');
  while (path.startsWith('/')) {
    path = path.substring(1);
  }
  return path;
}

/// Split a normalized path into non-empty segments.
List<String> splitRemotePath(String normalized) =>
    normalized.split('/').where((segment) => segment.isNotEmpty).toList();

/// A direct subfolder of the folder being viewed, with the number of
/// files below it (recursively).
class FolderChild {
  FolderChild({required this.name, required this.fileCount});

  final String name;
  final int fileCount;
}

/// One level of the tree: direct subfolders plus direct files.
class FolderView<T> {
  FolderView({required this.folders, required this.files});

  final List<FolderChild> folders;
  final List<T> files;
}

/// Build the view for the folder at [prefix] (empty = drive root) from
/// the flat [items] list. Items whose path does not start with [prefix]
/// are ignored. Folders sort by name descending (newest date folders
/// first); files sort by file name descending.
FolderView<T> folderView<T>({
  required List<T> items,
  required String Function(T item) pathOf,
  List<String> prefix = const [],
}) {
  final folderCounts = <String, int>{};
  final files = <T>[];
  for (final item in items) {
    final segments = splitRemotePath(normalizeRemotePath(pathOf(item)));
    if (segments.length <= prefix.length) continue;
    var matches = true;
    for (var i = 0; i < prefix.length; i++) {
      if (segments[i] != prefix[i]) {
        matches = false;
        break;
      }
    }
    if (!matches) continue;
    final rest = segments.sublist(prefix.length);
    if (rest.length == 1) {
      files.add(item);
    } else {
      final name = rest.first;
      folderCounts[name] = (folderCounts[name] ?? 0) + 1;
    }
  }
  final folders = folderCounts.entries
      .map((entry) => FolderChild(name: entry.key, fileCount: entry.value))
      .toList()
    ..sort((a, b) => b.name.compareTo(a.name));
  files.sort((a, b) {
    final nameA = splitRemotePath(normalizeRemotePath(pathOf(a))).last;
    final nameB = splitRemotePath(normalizeRemotePath(pathOf(b))).last;
    return nameB.compareTo(nameA);
  });
  return FolderView(folders: folders, files: files);
}
