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

- `blocks` ist ein Array aus `delay`-, `activityWatchCheck`- und `step`-Blocken in genau der Reihenfolge, in der sie laufen sollen.
- Ein `delay`-Block enthaelt nur `seconds`.
- Ein `activityWatchCheck`-Block kann `url`, `retryDelaySeconds` und `maxRetries` direkt enthalten. Alternativ akzeptiert der Launcher auch ein eingebettetes `activityWatch`-Objekt mit denselben Feldern.
- Ein `step`-Block enthaelt `name` und `scripts`.
- `scripts` enthaelt die zu startenden Script-Dateien.
- Ein Script kann mit `"enabled": false` deaktiviert bleiben, ohne den Eintrag zu loeschen.
- Wenn `path` auf eine `.py`-Datei zeigt, startet der Launcher sie mit `python` oder `py`.
- Wenn `path` ein Ordner ist, sucht der Launcher nach `main.py`, genau einer `.py`-Datei oder notfalls genau einer `.ps1`-Datei.
- Alte Configs mit `startupDelaySeconds` und `steps` werden weiterhin gelesen, aber der Launcher gibt dann einen Hinweis und empfiehlt die Umstellung auf `blocks`.
- Der `activityWatchCheck`-Block kann an beliebiger Stelle in `blocks` eingefuegt werden, um die Warteposition im Ablauf zu steuern. Wenn ActivityWatch noch nicht online ist, wartet der Launcher `retryDelaySeconds` Sekunden und probiert es erneut, bis `maxRetries` erreicht ist.

## Beispiel

Die mitgelieferten lokalen Pfade sind bereits in `config.json` hinterlegt:

- `H:\AppDevelopment\ActivityWatch_Android-Import\google_drive_to_activitywatch.py`
- `H:\AppDevelopment\ActivityWatch_email_summary\activitywatch_email_summary.py`
- `H:\AppDevelopment\ActivityWatch_iPad_sync_import\main.py`
