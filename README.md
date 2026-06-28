# ActivityWatch Startup Launcher

Dieses Repo startet selbst erstellte ActivityWatch-Skripte in konfigurierbaren Stufen beim Windows-Login.

## Dateien

- `launcher.ps1` startet die konfigurierten Scripts.
- `launcher.vbs` sorgt dafuer, dass kein sichtbares Fenster aufpoppt.
- `config.json` ist die lokale private Config und wird nicht eingecheckt.
- `config.example.json` ist die Vorlage fuer neue Anpassungen.
- `setup-startup-shortcut.ps1` legt einen Startup-Shortcut an.

## Setup

1. `config.json` anpassen.
2. `setup-startup-shortcut.ps1` einmal ausfuehren.
3. Danach startet Windows den Launcher automatisch beim Login.

## Config-Modell

- `blocks` ist ein Array aus `delay`- und `step`-Blocken in genau der Reihenfolge, in der sie laufen sollen.
- Ein `delay`-Block enthaelt nur `seconds`.
- Ein `step`-Block enthaelt `name` und `scripts`.
- `scripts` enthaelt die zu startenden Pfade.
- Ein Script kann mit `"enabled": false` deaktiviert bleiben, ohne den Eintrag zu loeschen.
- Wenn `path` ein Ordner ist, sucht der Launcher automatisch nach genau einer `.ps1`-Datei im Ordner. Wenn mehrere gefunden werden, muss `scriptFile` gesetzt werden.
- Alte Configs mit `startupDelaySeconds` und `steps` werden weiterhin gelesen, aber der Launcher gibt dann einen Hinweis und empfiehlt die Umstellung auf `blocks`.

## Beispiel

Die mitgelieferten lokalen Pfade sind bereits in `config.json` hinterlegt:

- `H:\AppDevelopment\ActivityWatch_Android-Import`
- `H:\AppDevelopment\ActivityWatch_email_summary`
- `H:\AppDevelopment\ActivityWatch_iPad_sync_import`
