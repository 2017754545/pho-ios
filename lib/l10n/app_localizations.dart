import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh')
  ];

  /// No description provided for @local.
  ///
  /// In en, this message translates to:
  /// **'Local'**
  String get local;

  /// No description provided for @cloud.
  ///
  /// In en, this message translates to:
  /// **'Cloud'**
  String get cloud;

  /// No description provided for @files.
  ///
  /// In en, this message translates to:
  /// **'Files'**
  String get files;

  /// No description provided for @noFiles.
  ///
  /// In en, this message translates to:
  /// **'No files'**
  String get noFiles;

  /// No description provided for @folderFileCount.
  ///
  /// In en, this message translates to:
  /// **'{count} files'**
  String folderFileCount(int count);

  /// No description provided for @sync.
  ///
  /// In en, this message translates to:
  /// **'Sync'**
  String get sync;

  /// No description provided for @cloudSync.
  ///
  /// In en, this message translates to:
  /// **'Cloud sync'**
  String get cloudSync;

  /// No description provided for @localFolder.
  ///
  /// In en, this message translates to:
  /// **'Local folder'**
  String get localFolder;

  /// No description provided for @cloudStorage.
  ///
  /// In en, this message translates to:
  /// **'Cloud storage'**
  String get cloudStorage;

  /// No description provided for @backgroundSync.
  ///
  /// In en, this message translates to:
  /// **'Auto Sync'**
  String get backgroundSync;

  /// No description provided for @notSync.
  ///
  /// In en, this message translates to:
  /// **'not sync'**
  String get notSync;

  /// No description provided for @unsynchronizedPhotos.
  ///
  /// In en, this message translates to:
  /// **'Unsynchronized photos'**
  String get unsynchronizedPhotos;

  /// No description provided for @date.
  ///
  /// In en, this message translates to:
  /// **'Date'**
  String get date;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @photos.
  ///
  /// In en, this message translates to:
  /// **'photos'**
  String get photos;

  /// No description provided for @deleteThisPhoto.
  ///
  /// In en, this message translates to:
  /// **'Delete this photo?'**
  String get deleteThisPhoto;

  /// No description provided for @deleteThisPhotos.
  ///
  /// In en, this message translates to:
  /// **'Delete this photos?'**
  String get deleteThisPhotos;

  /// No description provided for @cantBeUndone.
  ///
  /// In en, this message translates to:
  /// **'This action can\'t be undone'**
  String get cantBeUndone;

  /// No description provided for @download.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get download;

  /// No description provided for @upload.
  ///
  /// In en, this message translates to:
  /// **'Upload'**
  String get upload;

  /// No description provided for @success.
  ///
  /// In en, this message translates to:
  /// **'success'**
  String get success;

  /// No description provided for @choose.
  ///
  /// In en, this message translates to:
  /// **'Choose'**
  String get choose;

  /// No description provided for @stop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get stop;

  /// No description provided for @uploadFailed.
  ///
  /// In en, this message translates to:
  /// **'Upload failed'**
  String get uploadFailed;

  /// No description provided for @uploaded.
  ///
  /// In en, this message translates to:
  /// **'Uploaded'**
  String get uploaded;

  /// No description provided for @notUploaded.
  ///
  /// In en, this message translates to:
  /// **'Not uploaded'**
  String get notUploaded;

  /// No description provided for @chooseAlbum.
  ///
  /// In en, this message translates to:
  /// **'Choose album'**
  String get chooseAlbum;

  /// No description provided for @storageSetting.
  ///
  /// In en, this message translates to:
  /// **'Storage setting'**
  String get storageSetting;

  /// No description provided for @remoteStorageType.
  ///
  /// In en, this message translates to:
  /// **'Remote storage type'**
  String get remoteStorageType;

  /// No description provided for @samvbaServerAddress.
  ///
  /// In en, this message translates to:
  /// **'Samba server address'**
  String get samvbaServerAddress;

  /// No description provided for @username.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get username;

  /// No description provided for @password.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get password;

  /// No description provided for @share.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get share;

  /// No description provided for @rootPath.
  ///
  /// In en, this message translates to:
  /// **'Root path(Your photos will be uploaded to this path)'**
  String get rootPath;

  /// No description provided for @optional.
  ///
  /// In en, this message translates to:
  /// **'optional'**
  String get optional;

  /// No description provided for @testStorage.
  ///
  /// In en, this message translates to:
  /// **'Test storage'**
  String get testStorage;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @enableBackgroundSync.
  ///
  /// In en, this message translates to:
  /// **'Enable background sync'**
  String get enableBackgroundSync;

  /// No description provided for @syncOnlyOnWifi.
  ///
  /// In en, this message translates to:
  /// **'Sync only on WIFI'**
  String get syncOnlyOnWifi;

  /// No description provided for @syncInterval.
  ///
  /// In en, this message translates to:
  /// **'Sync interval'**
  String get syncInterval;

  /// No description provided for @minite.
  ///
  /// In en, this message translates to:
  /// **'minite'**
  String get minite;

  /// No description provided for @hour.
  ///
  /// In en, this message translates to:
  /// **'hour'**
  String get hour;

  /// No description provided for @day.
  ///
  /// In en, this message translates to:
  /// **'day'**
  String get day;

  /// No description provided for @week.
  ///
  /// In en, this message translates to:
  /// **'week'**
  String get week;

  /// No description provided for @month.
  ///
  /// In en, this message translates to:
  /// **'month'**
  String get month;

  /// No description provided for @year.
  ///
  /// In en, this message translates to:
  /// **'year'**
  String get year;

  /// No description provided for @chineseday.
  ///
  /// In en, this message translates to:
  /// **''**
  String get chineseday;

  /// No description provided for @yes.
  ///
  /// In en, this message translates to:
  /// **'Yes'**
  String get yes;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @setLocalFirst.
  ///
  /// In en, this message translates to:
  /// **'Please set local folder first'**
  String get setLocalFirst;

  /// No description provided for @downloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Download failed'**
  String get downloadFailed;

  /// No description provided for @storageNotSetted.
  ///
  /// In en, this message translates to:
  /// **'Remote storage is not setted,please set it first'**
  String get storageNotSetted;

  /// No description provided for @successfullyUpload.
  ///
  /// In en, this message translates to:
  /// **'Successfully upload'**
  String get successfullyUpload;

  /// No description provided for @skippedByUploadFilter.
  ///
  /// In en, this message translates to:
  /// **'skipped by upload filter'**
  String get skippedByUploadFilter;

  /// No description provided for @testSuccess.
  ///
  /// In en, this message translates to:
  /// **'Test success,you can save now'**
  String get testSuccess;

  /// No description provided for @connectFailed.
  ///
  /// In en, this message translates to:
  /// **'Storage connection failed'**
  String get connectFailed;

  /// No description provided for @selectRoot.
  ///
  /// In en, this message translates to:
  /// **'Select root path'**
  String get selectRoot;

  /// No description provided for @currentPath.
  ///
  /// In en, this message translates to:
  /// **'Current path'**
  String get currentPath;

  /// No description provided for @refreshingPleaseWait.
  ///
  /// In en, this message translates to:
  /// **'Comparing your local and cloud photos, the process may take longer if it\'s the first time running or if there are a large number of photos. Please be patient and wait.......'**
  String get refreshingPleaseWait;

  /// No description provided for @setRemoteStroage.
  ///
  /// In en, this message translates to:
  /// **'Please set cloud storage first'**
  String get setRemoteStroage;

  /// No description provided for @needPermision.
  ///
  /// In en, this message translates to:
  /// **'Need permission to access photos'**
  String get needPermision;

  /// No description provided for @gotoSystemSetting.
  ///
  /// In en, this message translates to:
  /// **'To browse the system album, you need to grant access permissions to the photo library. If necessary, please go to system settings to grant permission for accessing the photo library.'**
  String get gotoSystemSetting;

  /// No description provided for @openSetting.
  ///
  /// In en, this message translates to:
  /// **'Open settings'**
  String get openSetting;

  /// No description provided for @streamFallbackDownload.
  ///
  /// In en, this message translates to:
  /// **'Streaming failed, downloading for playback'**
  String get streamFallbackDownload;

  /// No description provided for @jumpTo.
  ///
  /// In en, this message translates to:
  /// **'Jump to'**
  String get jumpTo;

  /// No description provided for @onlyCamera.
  ///
  /// In en, this message translates to:
  /// **'Only camera'**
  String get onlyCamera;

  /// No description provided for @browseInRecents.
  ///
  /// In en, this message translates to:
  /// **'You can browse in recents'**
  String get browseInRecents;

  /// No description provided for @refreshing.
  ///
  /// In en, this message translates to:
  /// **'Refreshing photos,please wait...'**
  String get refreshing;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @desktopStorageSettingDesc.
  ///
  /// In en, this message translates to:
  /// **'Set up network storage to browse the photos you\'ve backed up using Pho'**
  String get desktopStorageSettingDesc;

  /// No description provided for @zoomIn.
  ///
  /// In en, this message translates to:
  /// **'Zoom in'**
  String get zoomIn;

  /// No description provided for @zoomOut.
  ///
  /// In en, this message translates to:
  /// **'Zoom out'**
  String get zoomOut;

  /// No description provided for @about.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// No description provided for @appVersion.
  ///
  /// In en, this message translates to:
  /// **'App version'**
  String get appVersion;

  /// No description provided for @installHEVCExtention.
  ///
  /// In en, this message translates to:
  /// **'If HEIC or HEVC formats cannot be displayed correctly, please install \"HEVC Video Extension\" in the Microsoft Store'**
  String get installHEVCExtention;

  /// No description provided for @openMSStore.
  ///
  /// In en, this message translates to:
  /// **'Install'**
  String get openMSStore;

  /// No description provided for @clearCache.
  ///
  /// In en, this message translates to:
  /// **'Clear cache'**
  String get clearCache;

  /// No description provided for @clearCacheDescription.
  ///
  /// In en, this message translates to:
  /// **'This operation will only clear the image cache and will not delete any of your configurations. Are you sure you want to clear the cache?'**
  String get clearCacheDescription;

  /// No description provided for @offline.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get offline;

  /// No description provided for @noLocalPhotos.
  ///
  /// In en, this message translates to:
  /// **'No photos found'**
  String get noLocalPhotos;

  /// No description provided for @noCloudPhotos.
  ///
  /// In en, this message translates to:
  /// **'No cloud photos'**
  String get noCloudPhotos;

  /// No description provided for @refreshUnsynchronizedPhotos.
  ///
  /// In en, this message translates to:
  /// **'Refresh unsynchronized photos'**
  String get refreshUnsynchronizedPhotos;

  /// No description provided for @onboardingWelcome.
  ///
  /// In en, this message translates to:
  /// **'Welcome to Pho'**
  String get onboardingWelcome;

  /// No description provided for @onboardingWelcomeDesc.
  ///
  /// In en, this message translates to:
  /// **'Your serverless photo sync tool'**
  String get onboardingWelcomeDesc;

  /// No description provided for @onboardingSyncTitle.
  ///
  /// In en, this message translates to:
  /// **'Sync to your storage'**
  String get onboardingSyncTitle;

  /// No description provided for @onboardingSyncDesc.
  ///
  /// In en, this message translates to:
  /// **'Supports SMB, WebDAV and NFS. Photos organized by date automatically'**
  String get onboardingSyncDesc;

  /// No description provided for @onboardingPrivacyTitle.
  ///
  /// In en, this message translates to:
  /// **'Your data, your control'**
  String get onboardingPrivacyTitle;

  /// No description provided for @onboardingPrivacyDesc.
  ///
  /// In en, this message translates to:
  /// **'No server, no database. Files stored directly in your network storage'**
  String get onboardingPrivacyDesc;

  /// No description provided for @onboardingSkip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get onboardingSkip;

  /// No description provided for @onboardingNext.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get onboardingNext;

  /// No description provided for @onboardingGetStarted.
  ///
  /// In en, this message translates to:
  /// **'Get Started'**
  String get onboardingGetStarted;

  /// No description provided for @onboardingStorageTitle.
  ///
  /// In en, this message translates to:
  /// **'Set up cloud storage (optional)'**
  String get onboardingStorageTitle;

  /// No description provided for @onboardingStorageDesc.
  ///
  /// In en, this message translates to:
  /// **'You can set up now or later in Settings'**
  String get onboardingStorageDesc;

  /// No description provided for @onboardingSetupStorage.
  ///
  /// In en, this message translates to:
  /// **'Set up storage'**
  String get onboardingSetupStorage;

  /// No description provided for @onboardingComplete.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get onboardingComplete;

  /// No description provided for @iosBackgroundSyncDescription.
  ///
  /// In en, this message translates to:
  /// **'iOS background sync is automatically scheduled by the system when charging, no manual interval setting required'**
  String get iosBackgroundSyncDescription;

  /// No description provided for @notificationDenied.
  ///
  /// In en, this message translates to:
  /// **'Notification permission not granted, sync works but no alerts'**
  String get notificationDenied;

  /// No description provided for @backgroundRefreshDisabledTitle.
  ///
  /// In en, this message translates to:
  /// **'Background App Refresh is off'**
  String get backgroundRefreshDisabledTitle;

  /// No description provided for @backgroundRefreshDisabledDesc.
  ///
  /// In en, this message translates to:
  /// **'Background sync cannot be triggered. Please go to Settings -> Pho to enable Background App Refresh, then go to Settings -> General -> Background App Refresh to confirm it\'s enabled globally'**
  String get backgroundRefreshDisabledDesc;

  /// No description provided for @backgroundRefreshDisabledAction.
  ///
  /// In en, this message translates to:
  /// **'Open Pho Settings'**
  String get backgroundRefreshDisabledAction;

  /// No description provided for @bgSyncSuccessNotificationTitle.
  ///
  /// In en, this message translates to:
  /// **'Pho Background Sync'**
  String get bgSyncSuccessNotificationTitle;

  /// No description provided for @bgSyncSuccessNotificationBody.
  ///
  /// In en, this message translates to:
  /// **'Successfully synced {count} photos'**
  String bgSyncSuccessNotificationBody(int count);

  /// No description provided for @bgSyncSuccessNotificationBodyWithFailures.
  ///
  /// In en, this message translates to:
  /// **'Successfully synced {succeeded} photos ({failed} failed)'**
  String bgSyncSuccessNotificationBodyWithFailures(int succeeded, int failed);

  /// No description provided for @parallelUploadCount.
  ///
  /// In en, this message translates to:
  /// **'Parallel uploads'**
  String get parallelUploadCount;

  /// No description provided for @parallelUploadCountDesc.
  ///
  /// In en, this message translates to:
  /// **'How many photos to upload at the same time (1–4). Higher values upload faster but use more battery and data. Background sync uploads at most 2 at a time.'**
  String get parallelUploadCountDesc;

  /// No description provided for @uploadFilter.
  ///
  /// In en, this message translates to:
  /// **'Upload filter'**
  String get uploadFilter;

  /// No description provided for @uploadFilterDesc.
  ///
  /// In en, this message translates to:
  /// **'Only upload photos that match the conditions. Excluded photos are not uploaded, not counted as pending, and not deleted; they re-enter the pending set automatically when the filter is relaxed.'**
  String get uploadFilterDesc;

  /// No description provided for @filterEnabled.
  ///
  /// In en, this message translates to:
  /// **'Enable filter'**
  String get filterEnabled;

  /// No description provided for @filterExcludeVideos.
  ///
  /// In en, this message translates to:
  /// **'Exclude videos'**
  String get filterExcludeVideos;

  /// No description provided for @filterExcludeImages.
  ///
  /// In en, this message translates to:
  /// **'Exclude photos'**
  String get filterExcludeImages;

  /// No description provided for @filterDateRangeInvalid.
  ///
  /// In en, this message translates to:
  /// **'The start date is after the end date. Fix the date range before saving.'**
  String get filterDateRangeInvalid;

  /// No description provided for @filterExcludesAll.
  ///
  /// In en, this message translates to:
  /// **'Excluding both photos and videos means nothing will be uploaded.'**
  String get filterExcludesAll;

  /// No description provided for @filterDateNotSet.
  ///
  /// In en, this message translates to:
  /// **'Not set'**
  String get filterDateNotSet;

  /// No description provided for @filterDateRange.
  ///
  /// In en, this message translates to:
  /// **'Date range (both end days included)'**
  String get filterDateRange;

  /// No description provided for @filterClearDates.
  ///
  /// In en, this message translates to:
  /// **'Clear dates'**
  String get filterClearDates;

  /// No description provided for @filterExtensions.
  ///
  /// In en, this message translates to:
  /// **'Extensions to exclude'**
  String get filterExtensions;

  /// No description provided for @filterExtensionsHint.
  ///
  /// In en, this message translates to:
  /// **'Comma-separated, e.g. gif, heic; leave empty to exclude none'**
  String get filterExtensionsHint;

  /// No description provided for @filterExtensionsDesc.
  ///
  /// In en, this message translates to:
  /// **'Extensions are case-insensitive. Extensions in the list are excluded; unlisted extensions are allowed.'**
  String get filterExtensionsDesc;

  /// No description provided for @onlyCameraDesc.
  ///
  /// In en, this message translates to:
  /// **'Only show camera photos in the gallery; screenshot albums are hidden. Photos saved to Recents by WeChat, WhatsApp and similar apps cannot be distinguished from camera photos and will still be shown. Sync is not affected.'**
  String get onlyCameraDesc;

  /// No description provided for @noCameraPhotos.
  ///
  /// In en, this message translates to:
  /// **'No camera photos in this album'**
  String get noCameraPhotos;

  /// No description provided for @manualUploadFolder.
  ///
  /// In en, this message translates to:
  /// **'Manual upload folder'**
  String get manualUploadFolder;

  /// No description provided for @manualUploadFolderDesc.
  ///
  /// In en, this message translates to:
  /// **'Manually uploaded files go to this folder under the drive root, sorted into video/ and image/ subfolders (not by date). Auto sync still uses the drive root with date folders. Leave empty to use the default folder \"manual\". Changing the folder does not move files already uploaded.'**
  String get manualUploadFolderDesc;

  /// No description provided for @manualUploadFolderHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. manual'**
  String get manualUploadFolderHint;

  /// No description provided for @manualUploadFolderBrowse.
  ///
  /// In en, this message translates to:
  /// **'Browse'**
  String get manualUploadFolderBrowse;

  /// No description provided for @manualUploadFolderEmpty.
  ///
  /// In en, this message translates to:
  /// **'Folder is empty; using the default folder \"manual\".'**
  String get manualUploadFolderEmpty;

  /// No description provided for @manualUploadFolderInvalid.
  ///
  /// In en, this message translates to:
  /// **'Invalid folder: use a path relative to the drive root, without \"..\", leading slash, or backslashes.'**
  String get manualUploadFolderInvalid;

  /// No description provided for @manualUploadFolderNotSet.
  ///
  /// In en, this message translates to:
  /// **'Set up remote storage first, then choose the manual upload folder.'**
  String get manualUploadFolderNotSet;

  /// No description provided for @manualUploadFolderPickerTitle.
  ///
  /// In en, this message translates to:
  /// **'Choose manual upload folder'**
  String get manualUploadFolderPickerTitle;

  /// No description provided for @manualUploadFolderCurrent.
  ///
  /// In en, this message translates to:
  /// **'Current: {folder}'**
  String manualUploadFolderCurrent(Object folder);

  /// No description provided for @manualUploadFolderRoot.
  ///
  /// In en, this message translates to:
  /// **'Drive root'**
  String get manualUploadFolderRoot;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
