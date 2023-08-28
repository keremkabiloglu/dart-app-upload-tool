import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:googleapis/androidpublisher/v3.dart' as androidpublisher;
import 'package:googleapis/androidpublisher/v3.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;

const Map<String, String> arguments = {
  'help': 'Show usable arguments.',
  'json': 'Service account json file path.',
  'file': 'App bundle (.aab) file path.',
  'package-name': 'Package name.',
};

late final ArgResults argResults;

void main(List<String> args) async {
  argResults = getArgResults(args);
  if (argResults['help']) {
    showHelp();
  } else {
    var jsonFilePath = argResults['json'];
    if (jsonFilePath == null) {
      logError(
        'Service Account json file path must be provided. --json <path to json file>',
      );
    } else {
      var serviceAccountJson = await readServiceAccountJson(jsonFilePath);
      if (serviceAccountJson != null) {
        var bundleFilePath = argResults['file'];
        if (bundleFilePath == null) {
          logError(
            'Bundle file path must be provided. --file <path to .aab file>',
          );
        } else {
          var aabFile = await getAabFile(bundleFilePath);
          if (aabFile != null) {
            var packageName = argResults['package-name'];
            if (packageName == null) {
              logError(
                'Package name must be provided --package-name <com.example.app>',
              );
            } else {
              var googleClient = await signInGoogle(serviceAccountJson);
              if (googleClient != null) {
                await uploadBundle(
                  client: googleClient,
                  aabFile: aabFile,
                  packageName: '$packageName',
                );
                exit(0);
              }
            }
          }
        }
      }
    }
  }
}

String getFileSizeString({required int bytes, int decimals = 0}) {
  const suffixes = ["B", "KB", "MB", "GB", "TB"];
  if (bytes == 0) return '0${suffixes[0]}';
  var i = (log(bytes) / log(1024)).floor();
  return ((bytes / pow(1024, i)).toStringAsFixed(decimals)) + suffixes[i];
}

Future<File?> getAabFile(String path) async {
  try {
    var file = File(path);
    var isExists = await file.exists();
    if (!isExists) {
      logError('File not exists. \'$path\'');
    } else {
      logMessage(
        'File readed ${file.path.split('/').last} (${getFileSizeString(bytes: await file.length(), decimals: 2)})',
      );
      return file;
    }
  } catch (e) {
    logError('File not exists. \'$path\'');
    return null;
  }
  return null;
}

Future<AutoRefreshingAuthClient?> signInGoogle(
  Map<String, dynamic> serviceAccountJson,
) async {
  var serviceAccountCredentials =
      ServiceAccountCredentials.fromJson(serviceAccountJson);
  logMessage('Signing google... (${serviceAccountCredentials.email})');
  try {
    var scopes = <String>['https://www.googleapis.com/auth/androidpublisher'];
    var httpClient = http.Client();
    return clientViaServiceAccount(
      serviceAccountCredentials,
      scopes,
      baseClient: httpClient,
    ).then((authCleint) {
      logMessage('Signin success.');
      return authCleint;
    });
  } catch (e) {
    logError('Signin fail.');
    return null;
  }
}

Future<void> uploadBundle({
  required AutoRefreshingAuthClient client,
  required File aabFile,
  required String packageName,
}) async {
  logMessage('App bundle uploading...');
  final publisher = androidpublisher.AndroidPublisherApi(client);
  late AppEdit appEdit;
  logMessage('Searching app edit...');
  try {
    appEdit = await publisher.edits.get(packageName, 'app-edit');
    logMessage('App edit found.');
  } catch (e) {
    logMessage('App edit not found, creating a new one.');
    appEdit = await publisher.edits.insert(
      AppEdit(id: 'app-edit'),
      packageName,
    );
    logMessage('App edit created.');
  }

  if (appEdit.id != null) {
    logMessage('Uploading app bundle...');
    try {
      var uploadedBundle = await publisher.edits.bundles.upload(
        packageName,
        appEdit.id!,
        uploadMedia: Media(
          aabFile.readAsBytes().asStream(),
          aabFile.lengthSync(),
        ),
      );
      logMessage(
        'App bundle uploaded. Version Code: ${uploadedBundle.versionCode}',
      );
      logMessage('Getting tracks...');
      late final TracksListResponse tracksListResponse;
      try {
        tracksListResponse =
            await publisher.edits.tracks.list(packageName, appEdit.id!);
        if (tracksListResponse.tracks != null ||
            tracksListResponse.tracks!.isNotEmpty) {
          var internalTestTrack = tracksListResponse.tracks!.firstWhere(
            (track) => track.track == 'internal',
            orElse: () => Track(),
          );
          if (internalTestTrack.track != null &&
              internalTestTrack.track == 'internal') {
            if (internalTestTrack.releases != null) {
              internalTestTrack.releases!.add(
                TrackRelease(
                  name: '${internalTestTrack.releases!.length}',
                  status: 'inProgress',
                  userFraction: 0.9999,
                  versionCodes: ['${uploadedBundle.versionCode}'],
                  inAppUpdatePriority: 5,
                  releaseNotes: [
                    LocalizedText(
                      language: 'tr-TR',
                      text: 'Hata düzeltmeleri ve performans iyileştirmeleri.',
                    ),
                    LocalizedText(
                      language: 'en-US',
                      text: 'Bug fixes and performance improvements.',
                    ),
                  ],
                ),
              );
              logMessage('Updating ${internalTestTrack.track}...');
              try {
                await publisher.edits.tracks
                    .update(
                  internalTestTrack,
                  packageName,
                  appEdit.id!,
                  internalTestTrack.track!,
                )
                    .then((updatedTrack) {
                  logMessage('Track update completed.');
                  logMessage('New release added to ${updatedTrack.track}.');
                  logMessage(
                      'Total releases: ${updatedTrack.releases!.length}.');
                });
              } catch (e) {
                logError('Track could not updated. $e');
              }
            } else {
              logError('Track releases is null.');
            }
          } else {
            logError('Internal test track nout found.');
          }
        } else {
          logError('Tracks is null or empty.');
        }
        await publisher.edits.commit(packageName, appEdit.id!).then((_) {
          logMessage('App edit commited.');
        });
      } catch (e) {
        logError('Tracks could not got. $e');
        rethrow;
      }
    } catch (e) {
      logError('App bundle could not uploaded. $e');
    }
  } else {
    logError('App edit id is null.');
  }
}

Future<Map<String, dynamic>?> readServiceAccountJson(String path) async {
  try {
    if (!path.endsWith('.json')) {
      throw 'File must be .json file.';
    }
    var jsonString = await File(path).readAsString();
    return jsonDecode(jsonString);
  } catch (e) {
    logError('Service account file could not readed. \'$path\'');
    return null;
  }
}

ArgResults getArgResults(Iterable<String> args) {
  final parser = ArgParser();
  try {
    arguments.forEach((key, value) {
      if (key == 'help') {
        parser.addFlag(key, abbr: key.substring(0, 1), help: value);
      } else {
        parser.addOption(key, abbr: key.substring(0, 1), help: value);
      }
    });
    return parser.parse(args);
  } catch (e) {
    logError(e);
    return parser.parse([]);
  }
}

void showHelp() {
  arguments.forEach((key, value) {
    logMessage('--$key: $value (-${key.substring(0, 1)})');
  });
}

void logMessage(Object? object) =>
    print('\x1B[32m[Google App Uploader]:\x1B[0m ${object.toString()}');
void logWarning(Object? object) =>
    print('\x1B[33m[Google App Uploader]:\x1B[0m ${object.toString()}');
void logError(Object? object) {
  print('\x1B[31m[Google App Uploader]:\x1B[0m ${object.toString()}');
  exit(1);
}
