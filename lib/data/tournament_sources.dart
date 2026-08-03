/// Statische Quellen-Tabellen. Bewusst aus home_screen.dart herausgeloest:
/// das sind Daten, keine Logik, und sie werden von Hand gepflegt.
library;

const List<Map<String, Object>> virtualTournamentData = [
  {
    'id': '__vienna_2024__',
    'title': 'Vienna Major 2024',
    'mediaIds': ['4RG6E1wA', 'n6NDlmCj', 'XQVdmpFC', 'laCkprbO', 'FLZtiJ9Z',
      '8li0jBJe', '5JOX9Zpz', 'BOWRuzeN', 'VywVMOqw', 'd1NqbjrE',
      'ZpN2Vhnw', 'IRVhVQ2t', 'DCFk0ZYf', 'UVvmO0r9', '5FZAHSsV',
      '8XUQvIE3', 'ogri3G7h', 'RxqdUmDp', 'usMGFmN4', 'wD1zmqgb',
      'wtj3USLB', 'N8vHjvMY', 'TTVKq5tB', '2fX2rQ2A', 't3vVHMOk'],
  },
  {
    'id': '__gstaad_2024__',
    'title': 'Gstaad Elite 16 2024',
    'mediaIds': ['l0qOShMO', 'I1koTibO', 'iNbKD4di', 'tFFKBGyC', 'fh12jyMp',
      'Q4fhGHXb', 'n9lNrdhv', '3BKffIP4', 'uJAbnTbv', 'JsNjX9k3',
      'kC9a5m0F', 'czsKhte7', 'B8DJejXV', 'NTfMsa0g', 'AAuLHsCf',
      'xgYZIIL6', '9OR1dC3f', 'rF0dKawq', 'uo94x2LN', 'ldSojZLA',
      '4HeH8h2G', 'fUKcEDwH', 'qqoXMRUo', 'mnLEAed6', 'qL5OiaNx'],
  },
];

  // YouTube-Playlists werden als eigene Turniere ohne API-Key via RSS-Feed geladen
// (https://www.youtube.com/feeds/videos.xml?playlist_id=...). Klick öffnet YouTube App.
const List<String> youtubePlaylistIds = [
  'PLQUMXo3n8RdbkhsBbZIJE2Xm9iwe7oHW6',
  'PLQUMXo3n8RdaxKFvodbdAEdF7RDz9g37O',
  'PLQUMXo3n8Rdbne15axkZXDNnksOVVE6CB',
  'PLQUMXo3n8RdaWp2OaQCbl_4HjzD7HyANE',
];

  // Dynamische Laola1-Listen: URL → Cache der gefetchten Videos. Wird in
// _loadTournamentList befüllt (parallel zu YouTube + VBW) und in _loadVideos
// gelesen. So bleiben die Listen auch nach Neustart aktuell.
const List<Map<String, String>> laolaDynamicPlaylists = [
  {
    'id': '__laola_tour_pro__',
    'title': 'win2day Beach Volleyball Tour Pro',
    'baseUrl':
        'https://www.laola1.at/de/daten/videos/beachvolleyball/win2day-beachvolleyball-tour-pro/',
    'pages': '4',
  },
];
