/// Titel-Aufbereitung fuer VBW-Turniere.
library;

/// VBW benennt dasselbe Turnier je nach Quelle unterschiedlich: das
/// competition_item heisst "BPT Elite Rio de Janeiro 2026", die offizielle
/// Playlist, die nach dem Turnier dazu entsteht, "Rio de Janeiro I Elite I
/// 2026". Im Dropdown wechselte ein Turnier dadurch mitten im Betrieb seinen
/// Namen — erst Bridge-Schreibweise, spaeter Playlist-Schreibweise.
final RegExp _bridgeTitleRe =
    RegExp(r'^BPT\s+(Elite(?:\s+16)?|Challenge|Futures)\s+(.+?)\s+(20\d{2})$');

/// Zieht die Bridge-Schreibweise auf das Playlist-Format.
///
/// Bewusst eng gefasst: matcht das Muster nicht, bleibt der Titel
/// unveraendert. Lieber ein untypischer Name als ein zerschnittener — VBW
/// hat neben den Turnieren auch Eintraege wie "Beach Volleyball World
/// Championships 2025", die kein Location/Level/Jahr-Schema haben.
String normalizeBridgeTournamentTitle(String raw) {
  final m = _bridgeTitleRe.firstMatch(raw.trim());
  if (m == null) return raw;
  return '${m.group(2)} I ${m.group(1)} I ${m.group(3)}';
}
