# AI Accounts

Eine native macOS-Menüleisten-App für gespeicherte Codex- und Claude-Code-Konten, verfügbare Limits und den bestätigten Kontowechsel. Die Oberfläche zeigt Kontoname und E-Mail, folgt dem hellen oder dunklen Erscheinungsbild und verwendet unter macOS 26 und neuer die nativen Glas-Bedienelemente. Mindestversion: macOS 14.

[Aktuelle Version herunterladen](https://github.com/LoggeL/codex-konten/releases/latest)

Dieses Projekt ist unabhängig und wird nicht von OpenAI entwickelt oder unterstützt.

## Installation und Updates

Das ZIP aus den Releases entpacken und `AI Accounts.app` nach `/Applications` kopieren. Die derzeitigen Builds sind lokal ad hoc signiert und nicht von Apple notarisiert. Gatekeeper kann den ersten Start deshalb blockieren. Hinweise zum bewussten Öffnen einer solchen App stehen bei [Apple](https://support.apple.com/102445).

Im Menü mit den drei Punkten steht **Nach Updates suchen …**. Dort lässt sich auch die automatische Update-Prüfung ein- und ausschalten. [Sparkle](https://sparkle-project.org/) lädt den öffentlichen [Update-Feed](https://raw.githubusercontent.com/LoggeL/codex-konten/main/appcast.xml) und überprüft die Ed25519-Signatur eines Update-Pakets vor der Installation. Diese Signatur ersetzt keine Apple-Notarisierung. Ein Update darf keinen laufenden Kontovorgang durch einen Neustart unterbrechen.

Die Update-Prüfung benötigt keine Codex-Zugangsdaten. Die App verwendet keine eigene Telemetrie. Update-Anfragen gehen an GitHub; GitHub sieht dabei die üblichen Verbindungsdaten einer HTTP-Anfrage.

## Bedienung

Der Prozentwert in der Menüleiste öffnet die Kontenübersicht. Er zeigt das verbleibende Wochenlimit des aktiven Kontos oder, wenn dieses fehlt, das 5-Stunden-Limit. Während des Ladens erscheint „…“. Die Werte laden beim Start und aktualisieren sich alle fünf Minuten sowie nach einem Kontowechsel. **Aktiv** bezeichnet die tatsächlich gelesene Codex-Anmeldung. Es erscheinen nur Limits, die Codex liefert, mit verbleibendem Prozentsatz und Rücksetzzeit. Ein Wochenlimit bedeutet nicht, dass zusätzlich ein 5-Stunden-Limit verfügbar sein muss. Daten nach mehr als 15 Minuten sind als veraltet markiert; Fehler lassen vorhandene Werte sichtbar.

Die dünne Marke im Limitbalken zeigt, wie viel bei gleichmäßigem Verbrauch bis zum Reset noch frei sein sollte. Darunter steht die Abweichung in Prozentpunkten (PP) als Defizit oder Reserve. Die Reichweite beruht auf dem durchschnittlichen Verbrauch seit Beginn des aktuellen Fensters und ist eine Schätzung. Sie wird mit dem zuletzt abgerufenen Verbrauch berechnet; die Soll-Marke und die verbleibende Zeit laufen im geöffneten Fenster minütlich weiter. Ohne gültige Fensterdauer und Rücksetzzeit, während der ersten drei Prozent eines Fensters, bei abgelaufenem Fenster oder nach mehr als 15 Minuten ohne neue Daten steht „Prognose nicht verfügbar“.

Das Menüleistenelement bleibt nach dem Schließen der Übersicht und des Verwaltungsfensters sichtbar. Wird die bereits laufende App erneut geöffnet, erscheint die Übersicht. **Beenden** im Menü schließt die App.

**Konten verwalten** öffnet ein dauerhaftes Fenster. **Konto hinzufügen** startet die Browser-Anmeldung für ein benanntes Profil. Eine laufende Anmeldung kann abgebrochen werden. Ein inaktives Konto kann erneut angemeldet oder aus der Liste entfernt werden. Die geschützte Profildatei bleibt beim Entfernen erhalten; das aktive Konto lässt sich nicht entfernen.

**Wechseln** verlangt eine Bestätigung. Nach der Prüfung der Zielanmeldung werden Codex und seine erfassten Unterprozesse sofort erzwungen beendet. Laufende Aufgaben werden dabei unterbrochen. Die Anmeldung wird erst ausgetauscht, wenn das Beenden bestätigt ist. Codex wird anschließend neu geöffnet. Scheitert nur der abschließende Start, steht **Codex öffnen** auch separat bereit.

## Lokale Kontodaten

### Claude Code

Der Claude-Reiter erkennt die bestehende Abonnement-Anmeldung über `claude auth status`. Er zeigt das 5-Stunden- und Wochenlimit, das Claude liefert, mit verbleibenden Prozenten, Reset-Zeiten und derselben Pace-Berechnung. Der Menüleistenwert folgt dem ausgewählten Reiter. Vorhandene Claude-Code-Cachewerte bleiben bei Abruffehlern sichtbar und werden nach 15 Minuten als veraltet markiert.

**Konto hinzufügen** meldet ein neues Profil einmalig über `claude auth login --claudeai` im Browser an. Die App verwendet dafür ein eigenes `CLAUDE_CONFIG_DIR` und einen getrennten macOS-Schlüsselbundeintrag. Metadaten und Limitcache liegen weiterhin unter `~/Library/Application Support/Codex Konten/Claude/`. Die App schreibt keine Token in Profildateien und exportiert keine Anmeldedaten.

**Wechseln** verwendet die gespeicherte Anmeldung ohne erneuten Browser-Login. Abgelaufene Zugangstoken werden mit dem gespeicherten Refresh-Token erneuert. Die Zielidentität einschließlich Organisation wird vor dem Einsetzen online geprüft. Die bisherige Anmeldung wird in einem eigenen Schlüsselbundprofil erhalten. Bei fehlgeschlagener Prüfung nach dem Wechsel werden die vorherige Anmeldung und die ursprünglichen Kontometadaten wiederhergestellt. Eine vom Anbieter widerrufene Anmeldung benötigt weiterhin eine erneute Anmeldung.

Schließe laufende Claude-Code-Sitzungen vor dem Wechsel. Neue Sitzungen verwenden das gewählte Konto; Gesprächsdateien und Projektkonfiguration bleiben erhalten. Die Claude-Desktop-Anmeldung wird separat verwaltet. API-Schlüssel, Cloud-Anbieter und aktive Dateifallback-Anmeldungen werden nicht umgeschaltet. Bei Bedarf fragt macOS einmalig nach Schlüsselbundzugriff; automatische Hintergrundabfragen zeigen keine solchen Dialoge. Klicke für die ausdrückliche Freigabe auf **Limits aktualisieren**.

Die direkte Abfrage von Claude-Abonnementlimits verwendet die OAuth-Endpunkte des installierten Claude Code. Sie sind keine zugesicherte öffentliche API und können sich ändern. Referenzen: [Claude-Code-Anmeldung](https://code.claude.com/docs/en/authentication), [CLI-Befehle](https://code.claude.com/docs/en/cli-reference) und [Limitfelder](https://code.claude.com/docs/en/statusline).

### Codex

Die App verwendet den bestehenden Speicher von Codex Account Switcher unter `~/Library/Application Support/Codex Account Switcher/` sowie die aktive Dateianmeldung unter `~/.codex/auth.json`. Neue Nutzer können ihre Konten dort über die App anlegen. Profildateien werden nur lokal gelesen und geschrieben. Eigene Anmeldedateien erhalten Dateimodus `0600`, die Verzeichnisse `0700`.

Der bisherige Codex Account Switcher muss beendet sein, bevor AI Accounts einen Kontovorgang ausführt. Die App erkennt außerdem eine zweite eigene Instanz per Dateisperre. Codex-Konfigurationen mit `cli_auth_credentials_store = "keyring"` oder `"auto"` werden beim Umschalten abgewiesen: Hier wird ausschließlich die Dateianmeldung unterstützt. Es gibt keinen automatischen Kontowechsel.

Die Release-App enthält sowohl Apple-Silicon- als auch Intel-Code. Automatische Prüfungen sind zunächst ausgeschaltet; sie lassen sich im Menü aktivieren. Die Installation einer angebotenen Version bleibt eine ausdrückliche Aktion.

## Entwickeln

Swift 6.2 oder neuer und ein macOS-26-SDK oder neuer werden zum Bauen benötigt. Sparkle ist als genaue SwiftPM-Version festgelegt.

```sh
xcrun swift test
bash scripts/package-app.sh "$PWD/dist"
```

Das Paketier-Skript erstellt und prüft das App-Bundle. Es installiert oder startet die App nicht. GitHub Actions führt Tests und Paketprüfung aus; der private Update-Signierschlüssel bleibt im macOS-Schlüsselbund des Veröffentlichers.

Für Layoutprüfungen ohne echte Konten:

```sh
xcrun swift build
"$(xcrun swift build --show-bin-path)/AIAccounts" --preview /tmp/konten-hell.png
"$(xcrun swift build --show-bin-path)/AIAccounts" --preview /tmp/konten-dunkel.png --dark
"$(xcrun swift build --show-bin-path)/AIAccounts" --preview /tmp/konten-fehler.png --preview-error --manage
```

`--preview` liest keine Anmeldedaten. Die Offscreen-Bilder zeigen das Layout, nicht die GPU-gerenderten Glasflächen. Das paketierte Bundle lässt sich mit `open dist/"AI Accounts.app" --args --demo` als echte Menüleisten-App mit Beispielkonten starten. In diesem Modus werden weder Kontodienst noch Updater gestartet. `--dark` erzwingt nur für diese Demo das dunkle Erscheinungsbild.

Der native Lebenszyklustest verwendet ebenfalls nur Beispieldaten und beendet seine Testinstanz selbst. Er öffnet und schließt die Übersicht und das Verwaltungsfenster und prüft, ob Menüleistenelement und Prozentwert erhalten bleiben:

```sh
open -n dist/"AI Accounts.app" --args --lifecycle-self-test /tmp/ai-accounts-lifecycle-result.txt
cat /tmp/ai-accounts-lifecycle-result.txt
```

## Releases vorbereiten

`config/release.env` enthält Versionsnummer, aufsteigende Buildnummer und den öffentlichen Prüfschlüssel. Der private Schlüssel liegt unter dem Sparkle-Keychain-Konto `de.logge.codex-konten`; er wird weder exportiert noch in GitHub Actions hinterlegt. Für eine neue Veröffentlichung Version und Buildnummer ändern, testen und paketieren:

```sh
xcrun swift test
bash scripts/package-app.sh "$PWD/dist"
bash scripts/prepare-release.sh "$PWD/dist/release" "$PWD/dist/AI Accounts.app"
```

Das zweite Skript erzeugt ein Universal-ZIP, `SHA256SUMS` und einen Appcast mit Ed25519-Signatur. Zuerst ZIP und Prüfsumme als GitHub-Release zum passenden `v`-Tag veröffentlichen, dann die erzeugte `appcast.xml` ins Repository übernehmen und pushen. Bereits veröffentlichte Versionspakete bleiben unverändert. Nach der Veröffentlichung die Download-Adresse und den Feed abrufen und die Signatur des heruntergeladenen ZIPs prüfen. Auf einem anderen Mac kann aus dem Quellcode gebaut werden; offizielle Updates lassen sich nur mit dem vorhandenen Signierschlüssel veröffentlichen.

## Design und Lizenz

Die Oberfläche orientiert sich an [Apples Material-Richtlinien](https://developer.apple.com/design/human-interface-guidelines/materials) und [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass). macOS übernimmt die Popover-Fläche und wichtige Bedienelemente. Ältere macOS-Versionen verwenden Standard-Bedienelemente.

Der eigene Quellcode steht unter der [MIT-Lizenz](LICENSE). Sparkle und seine Komponenten behalten ihre eigenen Lizenzen, die im eingebetteten Framework enthalten sind.
