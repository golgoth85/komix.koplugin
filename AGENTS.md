# komix

Regole generali (infrastruttura, GitHub, deploy, zone delicate): `/workspace/AGENTS.md`. Ambiente di sviluppo e collaudo headless: repo `koreader` (`/workspace/koreader-source`).

## Scopo
Client [Komga](https://komga.org) per KOReader: sfoglia la libreria, cerca, scarica i libri in locale e sincronizza i progressi di lettura, con abbonamenti a categorie, collezioni, liste di lettura e serie. Pensato per lettori e-ink (provato su Kindle Scribe 10,2" e Kobo Libra 2). Nasce dalla fusione dei plugin `kokomga` (MIT) e `komga` (AGPL-3.0-or-later) con funzioni aggiunte; il codice derivato dal secondo mantiene licenza, header SPDX e attribuzione.

## Funzionamento
- `main.lua` (ingresso) e moduli in `komix/core` e `komix/ui`, nello stesso namespace per evitare collisioni con altri plugin. `_meta.lua` richiede `fullname`, `description`, `version`; la versione va incrementata a ogni pubblicazione.
- Versione corrente: `1.0.7` (release GitHub `v1.0.7`, 2026-09-13). La produzione `/koreader/plugins/komix.koplugin` ha lo stesso codice di questo repo; sui dispositivi si installa copiando la cartella (o lo zip) in `koreader/plugins/` oppure da uno store della community (repo `komix.koplugin` con topic `koreader-plugin`).
- Test e prove su schermo: nel repo `koreader` (`tests/run.sh`, `tools/run-koreader.sh`, server Komga finto). Questo repo non ha una suite propria.
- Rilascio: tag `v*` avvia `.github/workflows/release.yml`. Note di release e README in inglese, ricavate dal `CHANGELOG.md`.

## Regole
- Sviluppo sul clone `-source`, mai nella cartella di produzione: branch, PR, poi copia sul runtime.
- Local CI: profilo `profile-pending` (vedi `LOCAL_CI.md`), facoltativa e non bloccante; nessuna CI GitHub-hosted automatica. Il codice non attendibile non gira su runner persistenti con credenziali.

## Zone delicate
- Sincronizzazione dei progressi verso Komga (scrive sul server reale) e cancellazione dei download sul dispositivo.
- Pubblicazione di una release o degli store (versione in `_meta.lua`): la scaricano i dispositivi.

## Documenti
`README.md`, `CHANGELOG.md`, `ROADMAP.md`, `LOCAL_CI.md`.
