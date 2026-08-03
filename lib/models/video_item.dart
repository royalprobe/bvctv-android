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
  bool get isLive => eventState == 'LIVE' || eventState == 'LIVE_PUBLISHED';
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
