/// Die drei Auswahl-Sheets der AppBar-Zeile: Turnier, Spieler, Land.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';

class TournamentSheet extends StatefulWidget {
  final List<Map<String, String>> tournaments;
  final String currentId;
  final String allId;

  const TournamentSheet({super.key, required this.tournaments, required this.currentId, required this.allId});

  @override
  State<TournamentSheet> createState() => TournamentSheetState();
}

class TournamentSheetState extends State<TournamentSheet> {
  final _firstFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _firstFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _firstFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = [
      {'id': widget.allId, 'title': S.allTournaments},
      ...widget.tournaments,
    ];
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        margin: const EdgeInsets.symmetric(vertical: 10),
        width: 40, height: 4,
        decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
      ),
      Flexible(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(items.length, (i) {
              final id = items[i]['id']!;
              final title = items[i]['title']!;
              final isActive = id == widget.currentId;
              return Focus(
                onKeyEvent: i == 0 ? (_, event) {
                  if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.arrowUp) {
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                } : null,
                child: ListTile(
                  focusNode: i == 0 ? _firstFocus : null,
                  title: Text(title, style: TextStyle(
                    color: isActive ? Colors.orange : Colors.white70,
                    fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                  )),
                  trailing: isActive ? const Icon(Icons.check, color: Colors.orange, size: 18) : null,
                  onTap: () => Navigator.pop(context, id),
                ),
              );
            }),
          ),
        ),
      ),
      const SizedBox(height: 16),
    ]);
  }
}

class PlayerSearchSheet extends StatefulWidget {
  final List<String> players;
  final String? selected;
  const PlayerSearchSheet({super.key, required this.players, this.selected});

  @override
  State<PlayerSearchSheet> createState() => PlayerSearchSheetState();
}

class PlayerSearchSheetState extends State<PlayerSearchSheet> {
  final _ctrl = TextEditingController();
  final _firstFocus = FocusNode();
  final _searchFocus = FocusNode();
  bool _searchActive = false;
  bool _searchFocused = false;
  late List<String> _filtered;

  @override
  void initState() {
    super.initState();
    _filtered = widget.players;
    _ctrl.addListener(() {
      final q = _ctrl.text.toLowerCase();
      setState(() {
        _filtered = q.isEmpty
            ? widget.players
            : widget.players.where((p) => p.toLowerCase().contains(q)).toList();
      });
    });
    _searchFocus.addListener(() {
      if (mounted) {
        setState(() {
        _searchFocused = _searchFocus.hasFocus;
        if (!_searchFocus.hasFocus) _searchActive = false;
      });
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _firstFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _firstFocus.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          margin: const EdgeInsets.symmetric(vertical: 10),
          width: 40, height: 4,
          decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Focus(
            onFocusChange: (hasFocus) {
              if (mounted) {
                setState(() {
                _searchFocused = hasFocus;
                if (!hasFocus && !_searchFocus.hasFocus) _searchActive = false;
              });
              }
            },
            onKeyEvent: (_, event) {
              if (!_searchActive && event is KeyDownEvent &&
                  (event.logicalKey == LogicalKeyboardKey.select ||
                   event.logicalKey == LogicalKeyboardKey.enter)) {
                setState(() => _searchActive = true);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _searchFocus.requestFocus();
                });
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: TextField(
            controller: _ctrl,
            focusNode: _searchFocus,
            autofocus: false,
            readOnly: !_searchActive,
            onTap: () { if (!_searchActive) setState(() => _searchActive = true); },
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: S.searchPlayers,
              hintStyle: const TextStyle(color: Colors.white38),
              prefixIcon: const Icon(Icons.search, color: Colors.white38),
              suffixIcon: _ctrl.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, color: Colors.white38),
                      onPressed: () => _ctrl.clear(),
                    )
                  : null,
              filled: true,
              fillColor: _searchActive || _searchFocused ? const Color(0xFF2A2A2A) : const Color(0xFF161616),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          ),
        ),
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
          child: ListView(shrinkWrap: true, children: [
            ListTile(
              focusNode: _firstFocus,
              leading: Icon(Icons.people, size: 20,
                  color: widget.selected == null ? Colors.orange : Colors.white38),
              title: Text(S.allPlayers, style: TextStyle(
                color: widget.selected == null ? Colors.orange : Colors.white70,
                fontWeight: widget.selected == null ? FontWeight.bold : FontWeight.normal,
              )),
              onTap: () => Navigator.pop(context, ''),
            ),
            ..._filtered.map((p) => ListTile(
              leading: Icon(Icons.person, size: 20,
                  color: p == widget.selected ? Colors.orange : Colors.white38),
              title: Text(p, style: TextStyle(
                color: p == widget.selected ? Colors.orange : Colors.white70,
                fontWeight: p == widget.selected ? FontWeight.bold : FontWeight.normal,
              )),
              onTap: () => Navigator.pop(context, p),
            )),
          ]),
        ),
        const SizedBox(height: 16),
      ]),
    );
  }
}

class CountrySearchSheet extends StatelessWidget {
  final List<String> countries;
  final String? selected;
  const CountrySearchSheet({super.key, required this.countries, this.selected});

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        margin: const EdgeInsets.symmetric(vertical: 10),
        width: 40, height: 4,
        decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
      ),
      ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.6),
        child: ListView(shrinkWrap: true, children: [
          ListTile(
            leading: Icon(Icons.flag_outlined, size: 20,
                color: selected == null ? Colors.orange : Colors.white38),
            title: Text(S.allCountries, style: TextStyle(
              color: selected == null ? Colors.orange : Colors.white70,
              fontWeight: selected == null ? FontWeight.bold : FontWeight.normal,
            )),
            onTap: () => Navigator.pop(context, ''),
          ),
          ...countries.map((c) => ListTile(
            leading: Icon(Icons.flag, size: 20,
                color: c == selected ? Colors.orange : Colors.white38),
            title: Text(c, style: TextStyle(
              color: c == selected ? Colors.orange : Colors.white70,
              fontWeight: c == selected ? FontWeight.bold : FontWeight.normal,
            )),
            onTap: () => Navigator.pop(context, c),
          )),
        ]),
      ),
      const SizedBox(height: 16),
    ]);
  }
}
