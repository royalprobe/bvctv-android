import 'package:flutter_test/flutter_test.dart';
import 'package:vbtv_app/models/video_item.dart';

VideoItem item({
  String eventState = 'VOD_PUBLIC',
  DateTime? matchDate,
  DateTime? scheduledEnd,
  String? linkUrl,
}) =>
    VideoItem(
      id: 'x',
      title: 't',
      teams: 'A vs B',
      gender: 'Men',
      round: 'Final',
      tournament: 'Test',
      thumbnailUrl: '',
      duration: 0,
      matchDate: matchDate,
      eventState: eventState,
      scheduledEnd: scheduledEnd,
      linkUrl: linkUrl,
    );

void main() {
  final now = DateTime.now().toUtc();

  group('isLive', () {
    test('gilt fuer beide LIVE-Zustaende von VBW', () {
      expect(item(eventState: 'LIVE').isLive, isTrue);
      expect(item(eventState: 'LIVE_PUBLISHED').isLive, isTrue);
    });
    test('gilt nicht fuer VOD oder angesetzte Spiele', () {
      expect(item(eventState: 'VOD_PUBLIC').isLive, isFalse);
      expect(item(eventState: 'PRE_LIVE').isLive, isFalse);
      expect(item(eventState: 'INSTANT_VOD').isLive, isFalse);
    });
  });

  group('isUpcoming', () {
    test('nur wenn der Anpfiff in der Zukunft liegt', () {
      expect(item(matchDate: now.add(const Duration(hours: 3))).isUpcoming, isTrue);
      expect(item(matchDate: now.subtract(const Duration(hours: 3))).isUpcoming, isFalse);
    });
    /// Ohne Datum darf nichts ausgeblendet werden — _filteredVideos wirft
    /// Upcoming-Items raus, und ein Video ohne match_date waere sonst weg.
    test('ohne Datum nicht upcoming', () {
      expect(item(matchDate: null).isUpcoming, isFalse);
    });
  });

  group('isInstantVod', () {
    test('nur fuer den INSTANT_VOD-Zustand', () {
      expect(item(eventState: 'VOD_PUBLIC', matchDate: now).isInstantVod, isFalse);
    });
    test('laeuft 2h nach Spielende ab', () {
      expect(
        item(eventState: 'INSTANT_VOD', scheduledEnd: now.subtract(const Duration(minutes: 30)))
            .isInstantVod,
        isTrue,
      );
      expect(
        item(eventState: 'INSTANT_VOD', scheduledEnd: now.subtract(const Duration(hours: 3)))
            .isInstantVod,
        isFalse,
      );
    });
    test('faellt auf matchDate zurueck wenn kein Ende gesetzt ist', () {
      expect(
        item(eventState: 'INSTANT_VOD', matchDate: now.subtract(const Duration(hours: 5)))
            .isInstantVod,
        isFalse,
      );
    });
  });

  group('Quellen-Erkennung', () {
    test('unterscheidet Laola, Twitch, YouTube und VBW', () {
      expect(item(linkUrl: 'https://www.laola1.at/de/video/player/1/x').isLaola, isTrue);
      expect(item(linkUrl: 'twitch:12345').isTwitch, isTrue);
      expect(item(linkUrl: 'https://www.youtube.com/watch?v=abc').isYouTube, isTrue);
      expect(item(linkUrl: null).isExternal, isFalse);
    });
    /// isExternal steuert, ob per launchUrl eine fremde App aufgeht. Twitch
    /// laeuft im eigenen Player und darf deshalb NICHT extern sein.
    test('Twitch ist nicht extern', () {
      final t = item(linkUrl: 'twitch:12345');
      expect(t.isTwitch, isTrue);
      expect(t.isExternal, isFalse);
    });
    test('twitchVideoId schaelt das Praefix ab', () {
      expect(item(linkUrl: 'twitch:98765').twitchVideoId, '98765');
      expect(item(linkUrl: null).twitchVideoId, isNull);
    });
  });
}
