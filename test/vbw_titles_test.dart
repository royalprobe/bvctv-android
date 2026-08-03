import 'package:flutter_test/flutter_test.dart';
import 'package:vbtv_app/services/vbw_titles.dart';

void main() {
  group('Bridge-Titel normalisieren', () {
    /// Solange VBW die Turnier-Playlist noch nicht angelegt hat, kennt die App
    /// nur den competition_item-Namen. Ohne Normalisierung wechselt derselbe
    /// Eintrag im Dropdown spaeter seinen Namen.
    test('zieht die BPT-Schreibweise auf das Playlist-Format', () {
      expect(normalizeBridgeTournamentTitle('BPT Elite Rio de Janeiro 2026'),
          'Rio de Janeiro I Elite I 2026');
      expect(normalizeBridgeTournamentTitle('BPT Elite Hamburg 2026'),
          'Hamburg I Elite I 2026');
    });

    test('kennt die weiteren Turnier-Level', () {
      expect(normalizeBridgeTournamentTitle('BPT Elite 16 Itapema 2025'),
          'Itapema I Elite 16 I 2025');
      expect(normalizeBridgeTournamentTitle('BPT Challenge Baden 2026'),
          'Baden I Challenge I 2026');
      expect(normalizeBridgeTournamentTitle('BPT Futures Vaduz 2026'),
          'Vaduz I Futures I 2026');
    });

    test('laesst bereits normale Playlist-Titel in Ruhe', () {
      for (final t in [
        'Gstaad I Elite I 2026',
        'Ostrava | Elite 16 | 2025',
        '1XBet Brasilia I Elite I 2026',
      ]) {
        expect(normalizeBridgeTournamentTitle(t), t);
      }
    });

    /// Lieber ein untypischer Name als ein zerschnittener: was nicht sicher
    /// ins Schema passt, bleibt unveraendert.
    test('laesst alles Unbekannte unveraendert', () {
      for (final t in [
        'Beach Volleyball World Championships 2025',
        'Challenge Highlights',
        'BPT Elite Rio de Janeiro', // ohne Jahr
        'BPT 2026', // ohne Level und Ort
        '',
      ]) {
        expect(normalizeBridgeTournamentTitle(t), t);
      }
    });

    test('ignoriert umgebende Leerzeichen', () {
      expect(normalizeBridgeTournamentTitle('  BPT Elite Hamburg 2026  '),
          'Hamburg I Elite I 2026');
    });
  });
}
