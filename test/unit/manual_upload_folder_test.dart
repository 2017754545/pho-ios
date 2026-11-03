import 'package:flutter_test/flutter_test.dart';
import 'package:img_syncer/state_model.dart';
import 'package:img_syncer/storage/storage.dart';
import 'package:img_syncer/sync/manual_upload_folder.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 分目录功能：客户端目录值语义。归一化规则与服务端
/// SanitizeDestDir 保持一致（server/imgmanager/destdir_test.go），
/// 两边用例须同步改动。
void main() {
  group('normalizeManualUploadFolder', () {
    test('accepts plain and nested relative paths', () {
      expect(normalizeManualUploadFolder('manual'), 'manual');
      expect(normalizeManualUploadFolder('a/b'), 'a/b');
      expect(normalizeManualUploadFolder('  manual  '), 'manual');
      expect(normalizeManualUploadFolder('my photos'), 'my photos');
    });

    test('empty input means unset', () {
      expect(normalizeManualUploadFolder(null), isNull);
      expect(normalizeManualUploadFolder(''), isNull);
      expect(normalizeManualUploadFolder('   '), isNull);
    });

    test('rejects traversal, absolute, backslash, empty segments', () {
      for (final raw in [
        '../x',
        'a/../b',
        '/manual',
        'manual/',
        'a//b',
        r'a\b',
        'a/./b',
        '.',
        'live',
        'live/x',
        '.thumbnail',
        '.thumbnail/x',
        '2026',
        '20260102',
        '2026/x',
        'a/b/',
      ]) {
        expect(normalizeManualUploadFolder(raw), isNull, reason: raw);
      }
    });
  });

  group('manualFolderRelativeToRoot', () {
    test('SMB: root-relative spelling', () {
      expect(manualFolderRelativeToRoot('photos', 'photos/manual'),
          'manual');
      expect(manualFolderRelativeToRoot('photos', 'photos'), '');
      expect(manualFolderRelativeToRoot('', 'manual'), 'manual');
      expect(
          manualFolderRelativeToRoot('photos', 'photos/a/b'), 'a/b');
    });

    test('WebDAV/NFS: absolute spelling with trailing slash', () {
      expect(manualFolderRelativeToRoot('/photos/', '/photos/manual/'),
          'manual');
      expect(manualFolderRelativeToRoot('/photos/', '/photos/'), '');
      expect(manualFolderRelativeToRoot('/', '/manual/'), 'manual');
      expect(manualFolderRelativeToRoot('/photos', '/photos/manual'),
          'manual');
    });

    test('rejects traversal produced by navigation', () {
      expect(manualFolderRelativeToRoot('photos', 'photos/../evil'),
          isNull);
    });
  });

  group('picker path spelling', () {
    test('native root', () {
      expect(pickerNativeRoot(true, 'photos'), 'photos');
      expect(pickerNativeRoot(true, ''), '');
      expect(pickerNativeRoot(false, '/photos/'), '/photos/');
      expect(pickerNativeRoot(false, 'photos'), '/photos/');
      expect(pickerNativeRoot(false, ''), '/');
    });

    test('child path follows each form dialog join rule', () {
      expect(pickerChildPath(true, '', 'manual'), 'manual');
      expect(pickerChildPath(true, 'photos', 'manual'), 'photos/manual');
      expect(pickerChildPath(false, '/', 'manual'), '/manual/');
      expect(pickerChildPath(false, '/photos/', 'manual'),
          '/photos/manual/');
    });

    test('parent path never escapes the browse root', () {
      expect(pickerParentPath(true, 'photos', 'photos/manual'), 'photos');
      expect(pickerParentPath(true, 'photos', 'photos'), 'photos');
      expect(pickerParentPath(false, '/photos/', '/photos/manual/'),
          '/photos/');
      expect(pickerParentPath(false, '/photos/', '/photos/'), '/photos/');
      expect(pickerParentPath(false, '/', '/manual/'), '/');
    });
  });

  group('SettingModel dest dir', () {
    test('unset value defaults to manual', () {
      final model = SettingModel();
      expect(model.manualUploadFolder, '');
      expect(model.manualUploadDestDir, 'manual');
    });

    test('stored value is normalized, invalid falls back to manual', () {
      final model = SettingModel();
      model.setManualUploadFolder('photos/manual');
      expect(model.manualUploadDestDir, 'photos/manual');
      model.setManualUploadFolder('../evil');
      expect(model.manualUploadDestDir, 'manual');
      model.setManualUploadFolder('');
      expect(model.manualUploadDestDir, 'manual');
    });

    test('persistence round-trip through SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});
      await saveManualUploadFolder('photos/manual');
      expect(await loadManualUploadFolder(), 'photos/manual');
      await saveManualUploadFolder('');
      expect(await loadManualUploadFolder(), '');
    });
  });

  group('destDirHeaders', () {
    test('null/empty produces no header (auto-sync layout)', () {
      expect(destDirHeaders(null), isEmpty);
      expect(destDirHeaders(''), isEmpty);
    });

    test('manual value produces the Image-Dest-Dir header', () {
      expect(destDirHeaders('manual'), {'Image-Dest-Dir': 'manual'});
      expect(destDirHeaders('a/b'), {'Image-Dest-Dir': 'a/b'});
    });
  });
}
