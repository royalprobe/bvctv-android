import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../app_variant.dart';

class UpdateInfo {
  final String versionName;
  final String changelog;
  final String downloadUrl;
  const UpdateInfo({required this.versionName, required this.changelog, required this.downloadUrl});
}

class UpdateChecker {
  static const _apiUrl = 'https://api.github.com/repos/royalprobe/bvctv-android/releases/latest';
  static const _channel = MethodChannel('bvctv/update');
  static bool _sessionChecked = false;

  static Future<UpdateInfo?> checkOncePerSession() async {
    if (_sessionChecked) return null;
    _sessionChecked = true;
    return check();
  }

  static void resetSession() => _sessionChecked = false;

  static Future<UpdateInfo?> check() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final current = info.version;

      final res = await http.get(
        Uri.parse(_apiUrl),
        headers: {'Accept': 'application/vnd.github.v3+json'},
      ).timeout(const Duration(seconds: 10));

      if (res.statusCode != 200) return null;

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final tag = (data['tag_name'] as String).replaceFirst('v', '');
      final changelog = (data['body'] as String? ?? '').trim();

      if (!_isNewer(tag, current)) return null;

      // Am Release haengen die APKs BEIDER Varianten. Nur das Asset der
      // eigenen Variante ziehen — sonst wuerde sich die neutrale Variante
      // beim ersten Update in die gebrandete verwandeln (und umgekehrt).
      // 'bvctv-v' matcht dabei nicht 'bvctv-neutral-v', die Praefixe sind
      // ueberschneidungsfrei.
      final assets = (data['assets'] as List? ?? []).cast<Map<String, dynamic>>();
      final apk = assets
          .where((a) =>
              (a['name'] as String).startsWith(AppVariant.updateAssetPrefix) &&
              (a['name'] as String).endsWith('.apk'))
          .firstOrNull;
      if (apk == null) return null;

      return UpdateInfo(
        versionName: tag,
        changelog: changelog,
        downloadUrl: apk['browser_download_url'] as String,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> downloadAndInstall(
    String url,
    String version, {
    required void Function(double) onProgress,
    required void Function(String) onError,
  }) async {
    try {
      final client = http.Client();
      final request = http.Request('GET', Uri.parse(url));
      final response = await client.send(request);

      final total = response.contentLength ?? 0;
      var received = 0;

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/bvctv-update.apk');
      if (file.existsSync()) file.deleteSync();
      final sink = file.openWrite();

      await for (final chunk in response.stream) {
        received += chunk.length;
        sink.add(chunk);
        if (total > 0) onProgress(received / total);
      }
      await sink.flush();
      await sink.close();
      client.close();

      await _channel.invokeMethod<void>('installApk', {'path': file.path});
    } catch (e) {
      onError(e.toString());
    }
  }

  static bool _isNewer(String remote, String current) {
    List<int> parts(String v) =>
        v.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final r = parts(remote);
    final c = parts(current);
    for (var i = 0; i < r.length || i < c.length; i++) {
      final rv = i < r.length ? r[i] : 0;
      final cv = i < c.length ? c[i] : 0;
      if (rv != cv) return rv > cv;
    }
    return false;
  }
}
