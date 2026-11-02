// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get local => 'Local';

  @override
  String get cloud => 'Cloud';

  @override
  String get sync => 'Sync';

  @override
  String get cloudSync => 'Cloud sync';

  @override
  String get localFolder => 'Local folder';

  @override
  String get cloudStorage => 'Cloud storage';

  @override
  String get backgroundSync => 'Auto Sync';

  @override
  String get notSync => 'not sync';

  @override
  String get unsynchronizedPhotos => 'Unsynchronized photos';

  @override
  String get date => 'Date';

  @override
  String get delete => 'Delete';

  @override
  String get photos => 'photos';

  @override
  String get deleteThisPhoto => 'Delete this photo?';

  @override
  String get deleteThisPhotos => 'Delete this photos?';

  @override
  String get cantBeUndone => 'This action can\'t be undone';

  @override
  String get download => 'Download';

  @override
  String get upload => 'Upload';

  @override
  String get success => 'success';

  @override
  String get choose => 'Choose';

  @override
  String get stop => 'Stop';

  @override
  String get uploadFailed => 'Upload failed';

  @override
  String get uploaded => 'Uploaded';

  @override
  String get notUploaded => 'Not uploaded';

  @override
  String get chooseAlbum => 'Choose album';

  @override
  String get storageSetting => 'Storage setting';

  @override
  String get remoteStorageType => 'Remote storage type';

  @override
  String get samvbaServerAddress => 'Samba server address';

  @override
  String get username => 'Username';

  @override
  String get password => 'Password';

  @override
  String get share => 'Share';

  @override
  String get rootPath => 'Root path(Your photos will be uploaded to this path)';

  @override
  String get optional => 'optional';

  @override
  String get testStorage => 'Test storage';

  @override
  String get save => 'Save';

  @override
  String get enableBackgroundSync => 'Enable background sync';

  @override
  String get syncOnlyOnWifi => 'Sync only on WIFI';

  @override
  String get syncInterval => 'Sync interval';

  @override
  String get minite => 'minite';

  @override
  String get hour => 'hour';

  @override
  String get day => 'day';

  @override
  String get week => 'week';

  @override
  String get month => 'month';

  @override
  String get year => 'year';

  @override
  String get chineseday => '';

  @override
  String get yes => 'Yes';

  @override
  String get cancel => 'Cancel';

  @override
  String get setLocalFirst => 'Please set local folder first';

  @override
  String get downloadFailed => 'Download failed';

  @override
  String get storageNotSetted =>
      'Remote storage is not setted,please set it first';

  @override
  String get successfullyUpload => 'Successfully upload';

  @override
  String get skippedByUploadFilter => 'skipped by upload filter';

  @override
  String get testSuccess => 'Test success,you can save now';

  @override
  String get connectFailed => 'Storage connection failed';

  @override
  String get selectRoot => 'Select root path';

  @override
  String get currentPath => 'Current path';

  @override
  String get refreshingPleaseWait =>
      'Comparing your local and cloud photos, the process may take longer if it\'s the first time running or if there are a large number of photos. Please be patient and wait.......';

  @override
  String get setRemoteStroage => 'Please set cloud storage first';

  @override
  String get needPermision => 'Need permission to access photos';

  @override
  String get gotoSystemSetting =>
      'To browse the system album, you need to grant access permissions to the photo library. If necessary, please go to system settings to grant permission for accessing the photo library.';

  @override
  String get openSetting => 'Open settings';

  @override
  String get streamFallbackDownload =>
      'Streaming failed, downloading for playback';

  @override
  String get jumpTo => 'Jump to';

  @override
  String get onlyCamera => 'Only camera';

  @override
  String get browseInRecents => 'You can browse in recents';

  @override
  String get refreshing => 'Refreshing photos,please wait...';

  @override
  String get settings => 'Settings';

  @override
  String get desktopStorageSettingDesc =>
      'Set up network storage to browse the photos you\'ve backed up using Pho';

  @override
  String get zoomIn => 'Zoom in';

  @override
  String get zoomOut => 'Zoom out';

  @override
  String get about => 'About';

  @override
  String get appVersion => 'App version';

  @override
  String get installHEVCExtention =>
      'If HEIC or HEVC formats cannot be displayed correctly, please install \"HEVC Video Extension\" in the Microsoft Store';

  @override
  String get openMSStore => 'Install';

  @override
  String get clearCache => 'Clear cache';

  @override
  String get clearCacheDescription =>
      'This operation will only clear the image cache and will not delete any of your configurations. Are you sure you want to clear the cache?';

  @override
  String get offline => 'Offline';

  @override
  String get noLocalPhotos => 'No photos found';

  @override
  String get noCloudPhotos => 'No cloud photos';

  @override
  String get refreshUnsynchronizedPhotos => 'Refresh unsynchronized photos';

  @override
  String get onboardingWelcome => 'Welcome to Pho';

  @override
  String get onboardingWelcomeDesc => 'Your serverless photo sync tool';

  @override
  String get onboardingSyncTitle => 'Sync to your storage';

  @override
  String get onboardingSyncDesc =>
      'Supports SMB, WebDAV and NFS. Photos organized by date automatically';

  @override
  String get onboardingPrivacyTitle => 'Your data, your control';

  @override
  String get onboardingPrivacyDesc =>
      'No server, no database. Files stored directly in your network storage';

  @override
  String get onboardingSkip => 'Skip';

  @override
  String get onboardingNext => 'Next';

  @override
  String get onboardingGetStarted => 'Get Started';

  @override
  String get onboardingStorageTitle => 'Set up cloud storage (optional)';

  @override
  String get onboardingStorageDesc => 'You can set up now or later in Settings';

  @override
  String get onboardingSetupStorage => 'Set up storage';

  @override
  String get onboardingComplete => 'Done';

  @override
  String get iosBackgroundSyncDescription =>
      'iOS background sync is automatically scheduled by the system when charging, no manual interval setting required';

  @override
  String get notificationDenied =>
      'Notification permission not granted, sync works but no alerts';

  @override
  String get backgroundRefreshDisabledTitle => 'Background App Refresh is off';

  @override
  String get backgroundRefreshDisabledDesc =>
      'Background sync cannot be triggered. Please go to Settings -> Pho to enable Background App Refresh, then go to Settings -> General -> Background App Refresh to confirm it\'s enabled globally';

  @override
  String get backgroundRefreshDisabledAction => 'Open Pho Settings';

  @override
  String get bgSyncSuccessNotificationTitle => 'Pho Background Sync';

  @override
  String bgSyncSuccessNotificationBody(int count) {
    return 'Successfully synced $count photos';
  }

  @override
  String bgSyncSuccessNotificationBodyWithFailures(int succeeded, int failed) {
    return 'Successfully synced $succeeded photos ($failed failed)';
  }

  @override
  String get parallelUploadCount => 'Parallel uploads';

  @override
  String get parallelUploadCountDesc =>
      'How many photos to upload at the same time (1–4). Higher values upload faster but use more battery and data. Background sync uploads at most 2 at a time.';

  @override
  String get uploadFilter => 'Upload filter';

  @override
  String get uploadFilterDesc =>
      'Only upload photos that match the conditions. Excluded photos are not uploaded, not counted as pending, and not deleted; they re-enter the pending set automatically when the filter is relaxed.';

  @override
  String get filterEnabled => 'Enable filter';

  @override
  String get filterExcludeVideos => 'Exclude videos';

  @override
  String get filterExcludeImages => 'Exclude photos';

  @override
  String get filterDateRangeInvalid =>
      'The start date is after the end date. Fix the date range before saving.';

  @override
  String get filterExcludesAll =>
      'Excluding both photos and videos means nothing will be uploaded.';

  @override
  String get filterDateNotSet => 'Not set';

  @override
  String get filterDateRange => 'Date range (both end days included)';

  @override
  String get filterClearDates => 'Clear dates';

  @override
  String get filterExtensions => 'Extensions to exclude';

  @override
  String get filterExtensionsHint =>
      'Comma-separated, e.g. gif, heic; leave empty to exclude none';

  @override
  String get filterExtensionsDesc =>
      'Extensions are case-insensitive. Extensions in the list are excluded; unlisted extensions are allowed.';

  @override
  String get onlyCameraDesc =>
      'Only show camera photos in the gallery; screenshot albums are hidden. Photos saved to Recents by WeChat, WhatsApp and similar apps cannot be distinguished from camera photos and will still be shown. Sync is not affected.';

  @override
  String get noCameraPhotos => 'No camera photos in this album';
}
