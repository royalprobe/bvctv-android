# Hinweise für Claude Code

## Simon arbeitet an mehreren Rechnern
Der lokale Stand dieses Repos kann hinter `origin` liegen, weil Simon von mehreren
Computern aus an denselben Projekten arbeitet.

**Vor Code-Änderungen zuerst den aktuellen Stand holen:**
1. `git fetch` und prüfen, ob der lokale Branch hinter `origin` liegt.
2. Wenn hinterher **und** der Arbeitsbaum sauber ist → `git pull --ff-only`, bevor du editierst.
3. Bei uncommitteten lokalen Änderungen oder wenn kein Fast-Forward möglich ist →
   **nicht** automatisch mergen, sondern Simon warnen und nachfragen.

Nach abgeschlossenen Änderungen committen und pushen, damit der andere Rechner nachziehen kann.
