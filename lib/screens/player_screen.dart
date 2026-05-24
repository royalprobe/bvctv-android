import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'dart:async';
import '../l10n/strings.dart';

class PlayerScreen extends StatefulWidget {
  final String title;
  final String streamUrl;

  const PlayerScreen({super.key, required this.title, required this.streamUrl});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late VideoPlayerController _controller;
  bool _isInitialized = false;
  bool _showControls = true;
  bool _isPlaying = false;
  Timer? _hideControlsTimer;
  Timer? _seekTimer;
  Timer? _uiTimer;

  // Fake 2-Stunden-Timeline
  static const Duration _fakeDuration = Duration(hours: 2);
  Duration _fakePosition = Duration.zero;
  bool _isInBlackScreen = false;
  Timer? _blackScreenTimer;

  // Kodi-style accumulated seeking
  int _pendingSeekSeconds = 0;
  int _seekClickCount = 0;
  bool _seekingForward = true;
  String _seekOverlayText = '';
  bool _showSeekOverlay = false;

  final List<int> _seekSteps = [10, 30, 60, 180, 300, 600, 1200, 1800];
  final FocusNode _rootFocusNode = FocusNode(debugLabel: 'LaolaPlayerRoot');

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _initPlayer();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    // Sonst landet DPad-Left/Right auf dem Slider (5 % = 6 min Sprung) statt
    // bei _seek mit unseren 10s/30s/1m/3m/5m/10m/20m/30m-Stufen.
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft) {
      _seek(false);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _seek(true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.space) {
      _togglePlayPause();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      setState(() => _showControls = true);
      _startHideControlsTimer();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _initPlayer() async {
    // Master-URL direkt an ExoPlayer geben — keine eigene Variant-Auswahl mehr.
    // Hintergrund: die Laola-VOD-Streams haben absolute Variant-URLs mit
    // eigenen hdntc-Auth-Tokens, die im _pickBestVariantUrl-Pfad zu 403
    // führten. ExoPlayer macht ABR + folgt Auth-Redirects intern korrekt.
    // Referer/Origin/UA bleiben gesetzt, weil die Akamai-CDN den Header bei
    // jedem Segment-Request prüft.
    _controller = VideoPlayerController.networkUrl(
      Uri.parse(widget.streamUrl),
      httpHeaders: const {
        'Referer': 'https://www.laola1.at/',
        'Origin': 'https://www.laola1.at',
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
      },
    );
    await _controller.initialize();
    setState(() {
      _isInitialized = true;
      _isPlaying = true;
    });
    _controller.play();
    _startHideControlsTimer();

    // UI-Tick alle 500ms: Position synchronisieren und Video-Ende erkennen
    _uiTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted || _isInBlackScreen) return;
      final value = _controller.value;
      setState(() {
        _fakePosition = value.position;
        _isPlaying = value.isPlaying;
      });
      // Video zu Ende → auf schwarzen Bildschirm wechseln
      if (value.duration > Duration.zero &&
          value.position >= value.duration - const Duration(milliseconds: 600) &&
          !value.isPlaying &&
          !value.isBuffering) {
        _startBlackScreen();
      }
    });
  }

  void _startBlackScreen() {
    if (_isInBlackScreen) return;
    setState(() {
      _isInBlackScreen = true;
      _isPlaying = true;
      _fakePosition = _controller.value.duration;
    });
    _runBlackScreenTimer();
  }

  void _runBlackScreenTimer() {
    _blackScreenTimer?.cancel();
    _blackScreenTimer = Timer.periodic(const Duration(milliseconds: 500), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (!_isPlaying) return;
      setState(() {
        _fakePosition += const Duration(milliseconds: 500);
        if (_fakePosition >= _fakeDuration) {
          _fakePosition = _fakeDuration;
          t.cancel();
        }
      });
    });
  }

  void _seekToFakePosition(Duration target) {
    if (target < Duration.zero) target = Duration.zero;
    if (target > _fakeDuration) target = _fakeDuration;

    final actualDuration = _controller.value.duration;

    if (target <= actualDuration) {
      // Zurück ins echte Video
      _blackScreenTimer?.cancel();
      _controller.seekTo(target);
      _controller.play();
      setState(() {
        _isInBlackScreen = false;
        _fakePosition = target;
        _isPlaying = true;
      });
    } else {
      // In den schwarzen Bereich vorspulen
      _blackScreenTimer?.cancel();
      setState(() {
        _isInBlackScreen = true;
        _fakePosition = target;
        _isPlaying = true;
      });
      _runBlackScreenTimer();
    }
  }

  void _togglePlayPause() {
    if (_isInBlackScreen) {
      setState(() => _isPlaying = !_isPlaying);
    } else {
      final playing = !_isPlaying;
      setState(() => _isPlaying = playing);
      playing ? _controller.play() : _controller.pause();
    }
    _startHideControlsTimer();
  }

  void _startHideControlsTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _onTap() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _startHideControlsTimer();
  }

  int _getSeekSeconds(int clickCount) {
    if (clickCount <= 0) return 0;
    if (clickCount <= _seekSteps.length) return _seekSteps[clickCount - 1];
    return _seekSteps.last + (clickCount - _seekSteps.length) * 600;
  }

  void _seek(bool forward) {
    if (_seekingForward != forward) {
      _seekClickCount = 0;
      _pendingSeekSeconds = 0;
    }
    _seekingForward = forward;
    _seekClickCount++;
    _pendingSeekSeconds = _getSeekSeconds(_seekClickCount);

    setState(() {
      _showSeekOverlay = true;
      _seekOverlayText = '${forward ? '+' : '-'}${_formatSeekTime(_pendingSeekSeconds)}';
      _showControls = true;
    });

    _seekTimer?.cancel();
    _seekTimer = Timer(const Duration(milliseconds: 600), () {
      final target = forward
          ? _fakePosition + Duration(seconds: _pendingSeekSeconds)
          : _fakePosition - Duration(seconds: _pendingSeekSeconds);
      _seekToFakePosition(target);

      _seekClickCount = 0;
      _pendingSeekSeconds = 0;
      if (mounted) {
        setState(() => _showSeekOverlay = false);
        _startHideControlsTimer();
      }
    });
  }

  String _formatSeekTime(int seconds) {
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${seconds ~/ 60}min';
    return '${seconds ~/ 3600}h ${(seconds % 3600) ~/ 60}min';
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    _seekTimer?.cancel();
    _uiTimer?.cancel();
    _blackScreenTimer?.cancel();
    _rootFocusNode.dispose();
    _controller.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // Auf Fire Stick (landscape-only) zerlegt setPreferredOrientations
    // ([portraitUp]) das Layout der Übersicht — leere Liste lässt die
    // System-Default wirken, gleich wie in WebViewPlayerScreen.
    SystemChrome.setPreferredOrientations([]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _rootFocusNode,
        autofocus: true,
        onKeyEvent: _onKeyEvent,
        child: !_isInitialized
          ? const Center(child: CircularProgressIndicator(color: Colors.orange))
          : GestureDetector(
              onTap: _onTap,
              child: Stack(
                children: [
                  // Video oder schwarzer Bildschirm
                  if (!_isInBlackScreen)
                    Center(
                      child: AspectRatio(
                        aspectRatio: _controller.value.aspectRatio,
                        child: VideoPlayer(_controller),
                      ),
                    ),

                  // Links = zurück, rechts = vor
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () => _seek(false),
                          child: Container(color: Colors.transparent),
                        ),
                      ),
                      Expanded(
                        child: GestureDetector(
                          onTap: () => _seek(true),
                          child: Container(color: Colors.transparent),
                        ),
                      ),
                    ],
                  ),

                  // Seek-Overlay (Kodi-Style)
                  if (_showSeekOverlay)
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _seekingForward ? Icons.fast_forward : Icons.fast_rewind,
                              color: Colors.orange,
                              size: 48,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _seekOverlayText,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 32,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              S.tapCount(_seekClickCount),
                              style: const TextStyle(color: Colors.white54, fontSize: 14),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // Controls
                  if (_showControls) _buildControls(),
                ],
              ),
            ),
      ),
    );
  }

  Widget _buildControls() {
    final progress = (_fakePosition.inMilliseconds / _fakeDuration.inMilliseconds).clamp(0.0, 1.0);

    // Slider + IconButtons sind sonst fokussierbar und fangen DPad-Tasten ab.
    return ExcludeFocus(child: Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black87, Colors.transparent, Colors.transparent, Colors.black87],
        ),
      ),
      child: Column(
        children: [
          // Titel + Zurück-Button
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),

          const Spacer(),

          // Progressbar + Buttons
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                    activeTrackColor: Colors.orange,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Colors.orange,
                  ),
                  child: Slider(
                    value: progress,
                    onChanged: (v) {
                      _seekToFakePosition(_fakeDuration * v);
                      _startHideControlsTimer();
                    },
                  ),
                ),
                Row(
                  children: [
                    Text(
                      '${_formatDuration(_fakePosition)} / ${_formatDuration(_fakeDuration)}',
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.replay_10, color: Colors.white, size: 32),
                      onPressed: () => _seek(false),
                    ),
                    IconButton(
                      icon: Icon(
                        _isPlaying ? Icons.pause_circle : Icons.play_circle,
                        color: Colors.orange,
                        size: 56,
                      ),
                      onPressed: _togglePlayPause,
                    ),
                    IconButton(
                      icon: const Icon(Icons.forward_30, color: Colors.white, size: 32),
                      onPressed: () => _seek(true),
                    ),
                    const Spacer(),
                    const SizedBox(width: 80),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ));
  }
}
