/// Wiederverwendbare TV-Bausteine: Fokus-Rahmen fuer die D-Pad-Navigation,
/// scrollender Text und die Video-Kachel. Lagen vorher alle in
/// home_screen.dart und haben mit dessen Logik nichts zu tun.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import '../models/video_item.dart';

// ── Marquee (scrollender Text bei Fokus) ─────────────────────────────────────

class MarqueeText extends StatefulWidget {
  final String text;
  final bool focused;
  final TextStyle style;
  const MarqueeText({super.key, required this.text, required this.focused, required this.style});
  @override
  State<MarqueeText> createState() => MarqueeTextState();
}

class MarqueeTextState extends State<MarqueeText> {
  final _scroll = ScrollController();
  Timer? _timer;

  @override
  void didUpdateWidget(MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focused && !oldWidget.focused) { _startScroll(); }
    else if (!widget.focused && oldWidget.focused) { _resetScroll(); }
  }

  void _startScroll() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 600), () async {
      if (!mounted || !_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      if (max <= 0) return;
      await _scroll.animateTo(max,
          duration: Duration(milliseconds: (max * 22).round()),
          curve: Curves.linear);
    });
  }

  void _resetScroll() {
    _timer?.cancel();
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        child: Text(widget.text, style: widget.style, maxLines: 1),
      );
}

// ── VideoCard ─────────────────────────────────────────────────────────────────

class VideoCard extends StatefulWidget {
  final VideoItem video;
  final bool spoiler;
  final VoidCallback onPressed;
  final VoidCallback? onPreload;
  final Widget genderBadge;
  final Widget statusBadge;
  final String dateStr;
  const VideoCard({
    super.key,
    required this.video,
    required this.spoiler,
    required this.onPressed,
    required this.genderBadge,
    required this.statusBadge,
    required this.dateStr,
    this.onPreload,
  });
  @override
  State<VideoCard> createState() => VideoCardState();
}

class VideoCardState extends State<VideoCard> {
  bool _focused = false;
  /// Nur fuer DIESE Karte und nur bis sie aus dem Blickfeld scrollt — der
  /// State geht beim Recyceln verloren, was fuer einen Spoiler-Schutz genau
  /// richtig ist.
  bool _revealed = false;

  static List<String> _splitTeams(String teams) {
    final idx = teams.indexOf(' vs ');
    if (idx < 0) return [teams];
    return [teams.substring(0, idx).trim(), teams.substring(idx + 4).trim()];
  }

  @override
  Widget build(BuildContext context) {
    final video = widget.video;
    final teams = _splitTeams(video.teams);
    const teamStyle = TextStyle(fontSize: 12, fontWeight: FontWeight.bold);

    final hidden = widget.spoiler && !_revealed;

    return TvFocusButton(
      onPressed: widget.onPressed,
      borderRadius: 8,
      // Umschalter: langes Druecken deckt auf UND wieder zu. Nur auf Karten
      // die ueberhaupt unter Spoiler-Schutz stehen — sonst wuerde die
      // Aktivierung unnoetig aufs Loslassen verschoben.
      onLongPress: widget.spoiler
          ? () => setState(() => _revealed = !_revealed)
          : null,
      onFocusChanged: (focused) {
        setState(() => _focused = focused);
        if (focused) widget.onPreload?.call();
      },
      child: Container(
        decoration: BoxDecoration(color: const Color(0xFF1A1A1A), borderRadius: BorderRadius.circular(8)),
        padding: const EdgeInsets.all(10),
        child: video.isYouTube
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(children: [
                    widget.statusBadge,
                    const SizedBox(width: 6),
                    const Text('YouTube', style: TextStyle(color: Colors.white38, fontSize: 10)),
                  ]),
                  const SizedBox(height: 6),
                  Expanded(child: Text(video.title,
                    style: teamStyle, maxLines: 3, overflow: TextOverflow.ellipsis)),
                  Text(S.opensYouTube,
                    style: const TextStyle(color: Colors.white38, fontSize: 10)),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      widget.genderBadge,
                      if (video.gender.isNotEmpty) const SizedBox(width: 6),
                      Expanded(child: Text(S.localizeRound(video.round),
                        style: const TextStyle(color: Colors.white60, fontSize: 10),
                        overflow: TextOverflow.ellipsis)),
                      widget.statusBadge,
                    ]),
                    const SizedBox(height: 6),
                    if (hidden) ...[
                      Row(children: [
                        const Icon(Icons.lock_outline, size: 12, color: Colors.white30),
                        const SizedBox(width: 4),
                        Expanded(child: Text(S.spoilerActive,
                          style: const TextStyle(fontSize: 11, color: Colors.white30, fontStyle: FontStyle.italic))),
                      ]),
                      // Hinweis nur auf der fokussierten Karte — auf allen
                      // gleichzeitig waere die Kachelwand noch voller Text.
                      if (_focused) ...[
                        const SizedBox(height: 3),
                        Text(S.spoilerRevealHint,
                          style: const TextStyle(fontSize: 9, color: Colors.white24)),
                      ],
                    ] else ...[
                      MarqueeText(text: teams[0], focused: _focused, style: teamStyle),
                      if (teams.length > 1) ...[
                        const SizedBox(height: 2),
                        MarqueeText(text: teams[1], focused: _focused, style: teamStyle),
                      ],
                      // Selbst aufgedeckt: Gegenrichtung anbieten, sonst waere
                      // der Schutz fuer diese Karte unwiderruflich weg.
                      if (_revealed && _focused) ...[
                        const SizedBox(height: 3),
                        Text(S.spoilerHideHint,
                          style: const TextStyle(fontSize: 9, color: Colors.white24)),
                      ],
                    ],
                  ]),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(video.tournament,
                      style: const TextStyle(color: Colors.white38, fontSize: 10),
                      overflow: TextOverflow.ellipsis),
                    Text(widget.dateStr,
                      style: const TextStyle(color: Colors.white38, fontSize: 10)),
                  ]),
                ],
              ),
      ),
    );
  }
}

// ── TvFocusButton ─────────────────────────────────────────────────────────────

class TvFocusButton extends StatefulWidget {
  final Widget child;
  final VoidCallback onPressed;
  final double borderRadius;
  final bool autofocus;
  final void Function(bool)? onFocusChanged;
  /// Optional. Ist er gesetzt, feuert onPressed erst beim Loslassen — siehe
  /// Begruendung im State.
  final VoidCallback? onLongPress;

  const TvFocusButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.borderRadius = 8,
    this.autofocus = false,
    this.onFocusChanged,
    this.onLongPress,
  });

  @override
  State<TvFocusButton> createState() => TvFocusButtonState();
}

class TvFocusButtonState extends State<TvFocusButton> {
  bool _focused = false;
  /// Der laufende Tastendruck hat bereits ein onLongPress ausgeloest — beim
  /// Loslassen darf dann NICHT zusaetzlich onPressed feuern.
  bool _longPressFired = false;
  /// Der KeyDown dieses Tastendrucks ist HIER angekommen.
  ///
  /// Ohne diese Pruefung reicht ein KeyUp allein zum Ausloesen — und genau das
  /// passierte beim Beenden-Dialog: dessen Buttons feuern beim KeyDown und
  /// schliessen den Dialog, das KeyUp desselben Drucks landet danach auf der
  /// Videokachel darunter und hat das Video geoeffnet.
  bool _selectDownSeen = false;

  static bool _isSelect(KeyEvent e) =>
      e.logicalKey == LogicalKeyboardKey.select ||
      e.logicalKey == LogicalKeyboardKey.enter;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (f) {
        // Fokuswechsel mitten im Tastendruck: der angefangene Druck gehoert
        // nicht mehr uns.
        if (!f) { _selectDownSeen = false; _longPressFired = false; }
        setState(() => _focused = f);
        widget.onFocusChanged?.call(f);
      },
      onKeyEvent: (_, event) {
        if (!_isSelect(event)) return KeyEventResult.ignored;
        // Ohne Long-Press-Handler bleibt es beim alten Verhalten: sofort beim
        // Tastendruck ausloesen.
        if (widget.onLongPress == null) {
          if (event is KeyDownEvent) {
            widget.onPressed();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }
        // Mit Long-Press-Handler wird erst beim LOSLASSEN ausgeloest, sonst
        // wuerde das Gedrueckthalten zuerst das Video oeffnen und der
        // Long-Press liefe ins Leere.
        if (event is KeyDownEvent) {
          _selectDownSeen = true;
          _longPressFired = false;
          return KeyEventResult.handled;
        }
        // Ein KeyRepeat/KeyUp ohne eigenen KeyDown gehoert zu einem Druck, der
        // woanders begonnen hat (typisch: der Beenden-Dialog schliesst sich
        // beim KeyDown und wir bekommen nur noch das KeyUp ab). Ignorieren,
        // sonst oeffnet der Bestaetigungsklick das Video darunter.
        if (!_selectDownSeen) return KeyEventResult.ignored;
        if (event is KeyRepeatEvent) {
          if (!_longPressFired) {
            _longPressFired = true;
            widget.onLongPress!();
          }
          return KeyEventResult.handled;
        }
        if (event is KeyUpEvent) {
          if (!_longPressFired) widget.onPressed();
          _selectDownSeen = false;
          _longPressFired = false;
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onPressed,
        onLongPress: widget.onLongPress,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius + 3),
            border: Border.all(
              color: _focused ? Colors.orange : Colors.transparent,
              width: 3,
            ),
            boxShadow: _focused
                ? [BoxShadow(color: Colors.orange.withValues(alpha: 0.2), blurRadius: 6, spreadRadius: 0)]
                : null,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class TvFocusWrapper extends StatefulWidget {
  final Widget child;
  final double borderRadius;

  const TvFocusWrapper({super.key, required this.child, required this.borderRadius});

  @override
  State<TvFocusWrapper> createState() => TvFocusWrapperState();
}

class TvFocusWrapperState extends State<TvFocusWrapper> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      skipTraversal: true,
      onFocusChange: (f) => setState(() => _focused = f),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.borderRadius + 3),
          border: Border.all(color: _focused ? Colors.orange : Colors.transparent, width: 3),
          boxShadow: _focused
              ? [BoxShadow(color: Colors.orange.withValues(alpha: 0.6), blurRadius: 10, spreadRadius: 1)]
              : null,
        ),
        child: widget.child,
      ),
    );
  }
}
