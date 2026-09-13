# Changelog

## [1.0.3] - 2026-09-13

### Corretto
- **Avviso spurio "nessuna cartella di download"**: sfogliando i libri (per sapere quali sono
  già scaricati) il plugin mostrava un errore quando non era configurata una cartella di
  download. Ora la verifica del percorso è silenziosa; l'avviso compare solo quando si tenta
  davvero un download. I download di gruppo/abbonamento non mostrano l'avviso ripetutamente.

### Note
- Prima release verificata **su KOReader reale** (build Linux x86_64 in ambiente headless):
  navigazione, copertine, conteggi, nomi serie e cartella di download testati a schermo.

## [1.0.2] - 2026-09-13

### Corretto
- **Icona di ricerca sbagliata**: il nome `search` non esiste tra le icone di KOReader, quindi
  veniva mostrata l'icona di fallback (triangolo con "!"). Ora si usa `appbar.search`.
- **Sovrapposizione dei pulsanti**: il menù opzioni torna in alto a sinistra (slot previsto dal
  Menu, come nell'OPDS nativo) e la ricerca si sposta nella barra in basso a destra. Così il
  pulsante opzioni non finisce più sopra la ✕ di chiusura.

### Aggiunto
- **Barra di caricamento durante il download**: dialogo con barra di avanzamento (byte scaricati
  se il server fornisce la dimensione del file, altrimenti solo stato + nome file). Nei download
  multipli il sottotitolo mostra anche "(i di N)".
- **Conferma di download completato**: notifica a comparsa per ogni file scaricato
  ("Scaricato: …"), con riepilogo finale per i download in blocco.

## [1.0.1] - 2026-09-13

### Corretto
- **Barra del titolo**: il pulsante opzioni non si sovrappone più alla ricerca. La ricerca resta
  a sinistra (posizione standard), le opzioni vanno a destra.
- **Elenchi senza copertine** (home, librerie, collezioni): densità compatta come il Menu standard
  di KOReader, così stanno in una sola pagina; la dimensione pagina lato server è allineata a
  quella a schermo (prima potevano disallinearsi).
- **Read list e collezioni**: il conteggio non mostra più `(0)` — se il server non espone
  `bookCount`/`seriesCount` si usa la lunghezza di `bookIds`/`seriesIds`.
- **Read list**: ogni libro mostra anche il nome della serie.
- Corretto uno shadowing della funzione di traduzione `_` dentro i cicli `for _,` (poteva dare
  errore aprendo le opzioni con abbonamenti presenti).

### Aggiunto
- **Opzioni → Home screen**: mostra/nascondi ogni voce della schermata principale (es. On Deck,
  Recently Added Books).

## [1.0.0] - 2026-09-13

Prima versione: fusione di `kokomga` (v2.1.0) e `komga` (v2026.08.31.1).

### Aggiunto
- Ricerca per serie, dalla schermata principale e dalla barra del titolo (da `komga`).
- Navigazione di **collezioni**, **read list** (con copertina) e **one-shot**.
- **Abbonamenti** a read list / collezioni: download automatico dei nuovi fumetti, avviabile a
  mano o automaticamente al ritorno online.
- Metadati: fallback della descrizione dalla serie; scelta degli autori
  (disegnatore / scrittore / entrambi / nessuno).
- Download: template del nome, timeout di stallo e totale, retry con backoff (da `komga`).
- Selettore della cartella di download (PathChooser).

### Ereditato da kokomga
- Vista lista e griglia con copertine e badge, selezione multipla e download in blocco.
- Sincronizzazione dei progressi via KOSync, riconoscimento multi-livello dei libri.
- Download atomico, coda offline, pre-download in background, RTL automatico.
- Cache copertine, i18n, azioni dispatcher (ora `komix_*`).
