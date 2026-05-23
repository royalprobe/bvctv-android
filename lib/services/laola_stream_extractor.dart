import 'dart:async';
import 'dart:collection' show UnmodifiableListView;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/strings.dart';
import '../screens/player_screen.dart';

/// Lädt die Laola1-Player-Seite in einem HeadlessInAppWebView und versucht
/// per XHR/fetch-Interceptor die HLS-Manifest-URL (.m3u8) abzugreifen.
/// Erfolg → PlayerScreen, Fehler/Timeout → externer Browser als Fallback.
class LaolaStreamExtractor extends StatefulWidget {
  final String pageUrl;
  final String title;

  const LaolaStreamExtractor({
    super.key,
    required this.pageUrl,
    required this.title,
  });

  @override
  State<LaolaStreamExtractor> createState() => _LaolaStreamExtractorState();
}

class _LaolaStreamExtractorState extends State<LaolaStreamExtractor> {
  HeadlessInAppWebView? _headless;
  Timer? _timeout;
  bool _completed = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _status = S.isEn ? 'Extracting stream…' : 'Stream wird geladen…';
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  static const String _captureScript = r'''
(function() {
  if (window.__bvctvLaolaInjected) return;
  window.__bvctvLaolaInjected = true;
  function report(url) {
    if (!url || typeof url !== 'string') return;
    if (url.indexOf('.m3u8') >= 0 || url.indexOf('master.m3u8') >= 0) {
      try { window.flutter_inappwebview.callHandler('LaolaStream', url); } catch(e) {}
    }
  }
  // XHR
  try {
    var origOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function(method, url) {
      try { report(typeof url === 'string' ? url : (url && url.toString())); } catch(e) {}
      return origOpen.apply(this, arguments);
    };
  } catch(e) {}
  // fetch
  try {
    var origFetch = window.fetch;
    if (origFetch) {
      window.fetch = function(input, init) {
        try {
          var u = typeof input === 'string' ? input : (input && input.url);
          report(u);
        } catch(e) {}
        return origFetch.apply(this, arguments);
      };
    }
  } catch(e) {}
  // Periodisches Polling auf <video src> falls direkte URL (kein blob)
  var polls = 0;
  var poller = setInterval(function() {
    polls++;
    var v = document.querySelector('video');
    if (v && v.src && v.src.indexOf('blob:') !== 0) report(v.src);
    if (polls > 60) clearInterval(poller);
  }, 500);
})();
''';

  Future<void> _start() async {
    _timeout = Timer(const Duration(seconds: 25), () {
      if (!_completed) {
        debugPrint('[laola-extract] timeout');
        _finishWithFallback();
      }
    });

    _headless = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(widget.pageUrl)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        userAgent:
            'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
      ),
      initialUserScripts: UnmodifiableListView([
        UserScript(
          source: _captureScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      ]),
      onWebViewCreated: (controller) {
        controller.addJavaScriptHandler(
          handlerName: 'LaolaStream',
          callback: (args) {
            if (args.isEmpty || _completed) return;
            final url = args[0].toString();
            debugPrint('[laola-extract] captured: $url');
            _finishWithStream(url);
          },
        );
      },
      onLoadStop: (controller, url) {
        debugPrint('[laola-extract] page loaded: $url');
      },
      onReceivedError: (controller, request, error) {
        debugPrint(
            '[laola-extract] webview error: ${error.description} url=${request.url}');
      },
    );

    try {
      await _headless?.run();
    } catch (e) {
      debugPrint('[laola-extract] run exception: $e');
      _finishWithFallback();
    }
  }

  void _finishWithStream(String streamUrl) {
    if (_completed) return;
    _completed = true;
    _timeout?.cancel();
    try {
      _headless?.dispose();
    } catch (_) {}
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) =>
            PlayerScreen(title: widget.title, streamUrl: streamUrl),
      ),
    );
  }

  void _finishWithFallback() {
    if (_completed) return;
    _completed = true;
    _timeout?.cancel();
    try {
      _headless?.dispose();
    } catch (_) {}
    if (!mounted) return;
    Navigator.pop(context);
    launchUrl(Uri.parse(widget.pageUrl),
        mode: LaunchMode.externalApplication);
  }

  @override
  void dispose() {
    _timeout?.cancel();
    try {
      _headless?.dispose();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Colors.orange),
            const SizedBox(height: 24),
            Text(_status, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 8),
            Text(widget.title,
                style:
                    const TextStyle(color: Colors.white38, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
