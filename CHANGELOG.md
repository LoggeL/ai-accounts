# Änderungen

## 1.3.0

- Eigener Claude-Reiter mit 5-Stunden- und Wochenlimit, Reset-Zeiten sowie Defizit-/Reserve-Anzeige.
- Claude-Code-Konten lassen sich im Browser einmalig hinzufügen. Gespeicherte Schlüsselbund-Anmeldungen werden beim Wechsel wiederverwendet und bei Ablauf per Refresh-Token erneuert.
- Vor dem Wechsel müssen laufende Claude-Code-Sitzungen geschlossen sein. Gesprächsverlauf und Projekte bleiben erhalten. Claude Desktop verwaltet seine Anmeldung separat.
- Die Zielidentität wird vor dem Wechsel geprüft. Bei einem Fehler nach dem Einsetzen werden Anmeldung und Kontometadaten wiederhergestellt. Hintergrundabfragen öffnen keine Schlüsselbunddialoge.

## 1.2.4

- Jedes verfügbare Limit zeigt den linearen Soll-Verbrauch, die Abweichung in Prozentpunkten und eine Reichweitenprognose. Die Marke im Balken bezeichnet den Soll-Restwert.
- Für die Berechnung wird die von Codex gelieferte Fensterdauer gespeichert. Ohne gültige Dauer, nach Ablauf des Fensters oder bei veralteten Daten bleibt die Prognose aus.

## 1.2.3

- Das Menüleistenelement bleibt nach dem Schließen der Kontenübersicht und des Verwaltungsfensters bestehen. Ein erneuter App-Aufruf öffnet die Übersicht.
- Der Prozentwert des aktiven Kontos wird auf dem dauerhaft gehaltenen Menüleistenelement aktualisiert. „Beenden“ schließt die App weiterhin ausdrücklich.

## 1.2.2

- Der Menüleisteneintrag verwendet ein einzelnes Text-Label für den Prozentwert. Während des Ladens erscheint „…“.

## 1.2.1

- Die Menüleiste zeigt den verbleibenden Prozentsatz des aktiven Kontos. Bevorzugt wird das Wochenlimit, ersatzweise das 5-Stunden-Limit.
- Konten und Limits werden bereits beim Start und anschließend alle fünf Minuten geladen, auch wenn das Popover geschlossen bleibt.

## 1.2.0

- Überarbeitete Kontenübersicht mit E-Mail-Adressen, Aktiv-Text und voller Breite für die Limitbalken. Avatare und runde Schaltflächen-Hintergründe entfallen.
- Native Glas-Schaltflächen unter macOS 26 und neuer; Unterstützung für helles und dunkles Erscheinungsbild.
- Signierte Updates über Sparkle und GitHub Releases, manuelle Prüfung und Einstellung für automatische Prüfungen.
- Demo-Modus für Oberfläche und Konteninteraktionen mit synthetischen Beispieldaten.

## 1.1.0

- Codex-Neustart prüft den tatsächlichen Prozess und verwendet das zuvor laufende App-Bundle.
- Ein Timeout beim Beenden verhindert Änderungen an der aktiven Anmeldung.
- Separate Aktion zum Öffnen von Codex nach einem fehlgeschlagenen Start.
