# komix — client Komga per KOReader

`komix` è la fusione di due plugin KOReader per [Komga](https://komga.org):

- **kokomga** (MIT, © 2026 Jim Davis) — vista a lista e griglia con copertine, sincronizzazione
  dei progressi di lettura, metadati, cache copertine.
- **komga** (AGPL-3.0-or-later, © 2026 Jonathan Willian) — ricerca, collezioni, download con
  template del nome, retry e timeout configurabili.

La vista e il motore di sincronizzazione vengono da **kokomga**; la ricerca, il download
configurabile e le collezioni da **komga**. Collezioni, read list, one-shot e abbonamenti alle
categorie sono funzioni nuove.

## Funzioni

**Navigazione (stile kokomga)**
- Vista **lista** e **griglia** con copertine, badge di stato (nuovo / in corso / completato),
  badge "scaricato" e selezione multipla.
- Schermata principale: Ricerca, Keep Reading, On Deck, Serie recenti, Libri recenti, Tutte le
  serie, **Collezioni**, **Read list**, **One-shot**, Librerie, Sincronizza abbonamenti.
  Ogni voce si può mostrare/nascondere da **Opzioni → Home screen**.

**Ricerca (stile komga)**
- Ricerca per **serie**, raggiungibile sia dalla voce "Ricerca" in home sia dal pulsante di ricerca
  nella barra in basso, da qualsiasi catalogo. Il menù opzioni del catalogo (vista, righe, filtro)
  è in alto a sinistra.

**Collezioni, read list, one-shot**
- Sfoglia le **collezioni** (collezione → serie → libri) e le **read list** (read list → libri,
  con copertina dell'anteprima). Gli **one-shot** sono le serie composte da un solo libro.

**Sincronizzazione dei progressi (motore kokomga)**
- Intercetta KOSync e sincronizza i progressi direttamente con Komga per i libri riconosciuti.
- Riconoscimento multi-livello (cache → sidecar → metadata), download atomico `.part` → rename,
  coda offline, pre-download in background dei capitoli successivi, RTL automatico.

**Download**
- Template del nome (`{series}`, `{title}`, `{number}`), sottocartelle per serie, timeout di stallo
  e totale configurabili, retry con backoff su errori transitori.

**Metadati**
- Scrive titolo, descrizione, indice di serie e autori nei sidecar di KOReader.
- Se un capitolo non ha una descrizione, usa quella **della serie** che lo contiene (opzione).
- Scelta degli autori da salvare: **solo disegnatore** (predefinito), solo scrittore, entrambi,
  oppure nessuno.

**Abbonamenti alle categorie**
- Sottoscrivi una o più **read list** e/o **collezioni**: i nuovi fumetti aggiunti su Komga vengono
  scaricati automaticamente in locale.
- Avvio **manuale** ("Sincronizza abbonamenti" in home / menu / azione rapida) e **automatico**
  quando la rete torna disponibile.

## Installazione

Copia la cartella `komix.koplugin` in `koreader/plugins/` (oppure scompatta
`komix.koplugin.zip` lì dentro) e riavvia KOReader.

Configura il server in **Menu → komix → Server Setup** (URL e API key, oppure genera la API key
con utente e password). Imposta una cartella di download in **Menu → komix → Options**.

> Nota: se hai ancora installati `kokomga` e/o `komga`, puoi rimuoverli: `komix` include le loro
> funzioni. I moduli interni di `komix` vivono sotto il namespace `komix/` proprio per non entrare
> in conflitto con quelli degli altri plugin.

## Installazione da uno store della community

Oltre all'installazione manuale, `komix` è pensato per gli store della community KOReader
(es. **appstore.koplugin**, **KoStore**). Questi **non usano un registro centrale**: scoprono i
plugin cercando su GitHub per *topic* o per nome del repository. Perché `komix` venga trovato, il
repository GitHub deve avere:

- il **topic `koreader-plugin`** (nel repo: *About* → ingranaggio → *Topics*), **e/o**
- un nome che contenga **`.koplugin`** (es. `komix.koplugin`).

L'archivio installabile contiene la cartella `komix.koplugin/` con dentro un `_meta.lua` valido:
è il formato che gli store si aspettano.

## Pubblicare una nuova versione

1. Aggiorna **`version` in `_meta.lua`** (è il valore con cui gli store capiscono che c'è un
   aggiornamento) e aggiungi la voce in `CHANGELOG.md`.
2. Genera l'archivio: `tools/package-plugin.sh komix` → `komix.koplugin.zip`.
3. Pubblica una **release** su GitHub col tag della versione e allega `komix.koplugin.zip`.

In alternativa, `tools/publish-plugin.sh` automatizza i tre passi.

## Licenza

Opera combinata distribuita sotto **AGPL-3.0-or-later**, perché include codice derivato dal plugin
`komga` (AGPL-3.0-or-later). Le parti derivate da `kokomga` sono MIT. Vedi `LICENSE` e gli header
di attribuzione nei file.
