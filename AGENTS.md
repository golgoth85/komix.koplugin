# komix

Regole comuni di infrastruttura e sviluppo: `/workspace/AGENTS.md`.

## Funzionamento
- Client Komga per KOReader: navigazione/ricerca, download locali, progressi di lettura e abbonamenti a categorie/collezioni/liste/serie. Destinazione e-ink touch, Kindle Scribe e Kobo Libra 2.
- Ingresso `main.lua`, moduli `komix/core` e `komix/ui` in namespace unico. `_meta.lua` richiede fullname/description/version; incrementare versione per pubblicazioni autorizzate.
- Codice derivato dai plugin kokomga (MIT) e komga (AGPL-3.0-or-later): preservare licenze, header SPDX e attribuzione.
- Banco headless `/workspace/koreader-source`; runtime di prova `/koreader/plugins/komix.koplugin`. Estrarre i file del plugin dal commit pubblicato, preservare la copia precedente e distribuirli sul runtime solo per un intervento richiesto. Sui dispositivi copia/ZIP come da `README.md`.

## Zone delicate e verifica
- Progressi scritti sul Komga reale e cancellazioni sul dispositivo richiedono il percorso delle zone delicate. Tag v* pubblicano release: non crearli incidentalmente.
- Test in koreader-source (`tests/run.sh`, mock Komga e `tools/run-koreader.sh`), nessuna suite autonoma qui. Dimensioni con Screen:scaleBySize, niente animazioni e nomi compatibili FAT32/exFAT.
- README e note di release pubbliche restano in inglese; stato/versioni/prossime attività in `ROADMAP.md`, modifiche in `CHANGELOG.md`.
