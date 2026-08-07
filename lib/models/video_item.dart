/// Ein Video/Match aus einer der Quellen (VBW, Laola1, Twitch/GBT, YouTube).
/// Die Quelle steckt in linkUrl — siehe die isXxx-Getter.
library;

class VideoItem {
  final String id;
  final String title;
  final String teams;
  final String gender;
  final String round;
  final String tournament;
  final String thumbnailUrl;
  final int duration;
  final DateTime? matchDate;
  final String eventState;
  final DateTime? scheduledEnd;
  final String? linkUrl;

  const VideoItem({
    required this.id,
    required this.title,
    required this.teams,
    required this.gender,
    required this.round,
    required this.tournament,
    required this.thumbnailUrl,
    required this.duration,
    this.matchDate,
    this.eventState = 'VOD_PUBLIC',
    this.scheduledEnd,
    this.linkUrl,
  });

  bool get isExternal => linkUrl != null && !isTwitch;
  bool get isYouTube => linkUrl != null && linkUrl!.contains('youtube.com');
  bool get isLaola => linkUrl != null && linkUrl!.contains('laola1.at');
  // Twitch-Videos werden nicht extern per launchUrl geoeffnet — stattdessen
  // ueber TwitchStream.extractMasterUrl und dem native PlayerScreen.
  bool get isTwitch => linkUrl != null && linkUrl!.startsWith('twitch:');
  String? get twitchVideoId => isTwitch ? linkUrl!.substring(7) : null;
  /// VBW laesst event_state nach Spielende teils auf LIVE stehen — beobachtet
  /// an Eintraegen, deren Playlist bereits EXT-X-ENDLIST hatte, also
  /// nachweislich beendet war. Der LIVE-Badge blieb haengen und die Kachel
  /// wurde weiter nach oben einsortiert.
  ///
  /// Zwei Gegenproben, an echten Daten geprueft (Hamburg 2026):
  ///   * duration ist 0, solange nichts fertig aufgezeichnet ist (PRE_LIVE),
  ///     und wird beim Uebergang auf INSTANT_VOD/VOD_PUBLIC gesetzt (gemessen
  ///     2417-3131 s). Eine gesetzte Dauer heisst also: fertig.
  ///   * scheduledEnd steht immer exakt 8 h nach dem Start, ist also kein
  ///     echtes Spielende — taugt aber als harte Obergrenze. Danach laeuft
  ///     sicher nichts mehr.
  ///
  /// Die selbst gebauten Laola-/Twitch-Livestreams sind davon nicht betroffen:
  /// die setzen duration 0 und scheduledEnd null.
  bool get isLive {
    if (eventState != 'LIVE' && eventState != 'LIVE_PUBLISHED') return false;
    if (duration > 0) return false;
    final ende = scheduledEnd;
    if (ende != null && ende.toUtc().isBefore(DateTime.now().toUtc())) {
      return false;
    }
    return true;
  }
  bool get isInstantVod {
    if (eventState != 'INSTANT_VOD') return false;
    final end = scheduledEnd ?? matchDate;
    if (end == null) return true;
    return DateTime.now().toUtc().difference(end.toUtc()) < const Duration(hours: 2);
  }
  bool get isUpcoming {
    if (matchDate == null) return false;
    return matchDate!.isAfter(DateTime.now().toUtc());
  }
}
