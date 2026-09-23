# Ambiente di sviluppo Genropy dockerizzato

_Runtime Genropy in container, sorgenti sull’host._

[![English](https://img.shields.io/badge/lang-English-1f6feb?style=flat-square)](README.md)&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;[![License](https://img.shields.io/badge/license-Apache--2.0-6f42c1?style=flat-square)](LICENSE)&nbsp;![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-0aa344?style=flat-square)&nbsp;![Arch](https://img.shields.io/badge/arch-arm64%20%7C%20amd64-fd7e14?style=flat-square)&nbsp;![DB](https://img.shields.io/badge/db-PostgreSQL-336791?style=flat-square)

Il framework Genropy e le sue dipendenze di runtime girano in container, mentre
i sorgenti restano sull'host, bind-montati ed editabili con i soliti strumenti.
Ogni progetto ha il proprio stack isolato (app + PostgreSQL), quindi piu'
progetti possono girare in parallelo senza che le loro dipendenze Python collidano.

Sull'host non serve installare nulla oltre a Docker.

## Come funziona

Uno stack Compose per progetto, tutti generati dallo stesso
`compose.project.yaml` parametrico piu' un `.env` per progetto. Aggiungere un
progetto significa aggiungere un file env, non un altro YAML.

```
gnr-<progetto>
├── db     postgres, volume dedicato
└── app    gnr web daemon + gnr web serve (stesso container)
```

Il daemon e il web server condividono il container per necessita': il client
del site register verifica il PID del site daemon con `psutil.pid_exists()`,
che e' locale al PID namespace. Ogni progetto ha il proprio daemon grazie a
`<sitedaemon/>`, quindi non esiste un daemon condiviso che accoppi i progetti.

## Setup

```bash
cp .env.example .env     # verifica i percorsi dei sorgenti e HOST_UID / HOST_GID
```

`HOST_UID`/`HOST_GID` devono corrispondere a `id -u` / `id -g`. Contano davvero:
il daemon scrive file di stato nella directory del sito bind-montata, e un
ownership disallineato li rende scomodi da gestire dall'host.

## Uso quotidiano

```bash
./gnrdev new <progetto> [istanza]   # crea projects/<progetto>.env, alloca le porte
./gnrdev up <progetto>              # avvia lo stack
./gnrdev ls                         # progetti e loro stato
./gnrdev logs <progetto> -f         # log aggregati
./gnrdev down <progetto>            # ferma lo stack
```

`new` rileva l'istanza automaticamente quando il progetto ne ha una sola; se ne
ha piu' di una le elenca e chiede quale usare.

Al primo avvio `up` si accorge che il database e' vuoto ed esegue da solo
`gnr db migrate`: nessun passo manuale di bootstrap. Con `--no-dbmigrate` lo si
salta.

### Esempio: due progetti in parallelo

```bash
$ ./gnrdev new sandbox sandboxpg
==> created projects/sandbox.env
    project  : sandbox
    instance : sandboxpg
    web      : http://localhost:9000
    debugpy  : 9100

$ ./gnrdev up sandbox
$ ./gnrdev new edodevel && ./gnrdev up edodevel

$ ./gnrdev ls
PROJECT            INSTANCE         PORT   NETWORK        STATUS    DEBUG  URL
edodevel           edodevel         9001   -              running   -      http://localhost:9001
sandbox            sandboxpg        9000   -              running   -      http://localhost:9000
```

Gli stack sono del tutto indipendenti: fermarne o romperne uno non tocca gli
altri.

### Modifiche allo schema

```bash
./gnrdev dbcheck <progetto>      # mostra le differenze, non applica nulla
./gnrdev dbmigrate <progetto>    # le applica
```

Entrambi usano `gnr db migrate`. Su un progetto che non si conosce conviene
lanciare prima `dbcheck`: il migratore NG rileva differenze che il vecchio
`db setup` ignorava in silenzio, compresi i refusi nel modello.

### Altri comandi

```bash
./gnrdev rm <progetto>                 # rimuove container, volumi e configurazione
./gnrdev shell <progetto>              # bash nel container app
./gnrdev gnr <progetto> <args...>      # CLI gnr dentro il container
./gnrdev psql <progetto>               # client psql
./gnrdev restart <progetto>            # riavvia il servizio app
./gnrdev rebuild <progetto>            # ricostruisce l'immagine
```

`logs`, `shell` e `restart` accettano anche `<progetto>.<servizio>` per agire su
un singolo container:

```bash
./gnrdev logs sandbox.app -f           # solo l'applicazione
./gnrdev logs sandbox.db               # solo il database
./gnrdev shell sandbox.db              # shell nel container postgres
./gnrdev restart sandbox.db            # riavvia solo il database
```

Servizi: `app`, `db` (piu' `init-perms` e `framework-src`).

I container hanno hostname uguale al nome del container, quindi il prompt dice
dove ti trovi: `genro@gnr-sandbox-app`.

### Backup e restore

```bash
./gnrdev backup <progetto> [file] [--offline]
./gnrdev restore <progetto> <file> [--yes] [--online]
./gnrdev backups                             # elenca quelli gia' fatti
```

Un backup e' un singolo `pg_dumpall` compresso, quindi copre tutti i database
del cluster del progetto — cosa che conta per le istanze multidb, dove ogni
store e' un database a se'. Ruoli e database di servizio vengono filtrati: il
cluster appartiene al progetto e il suo ruolo esiste gia', quindi riapplicarli
produrrebbe solo errori durante il restore.

Senza nome file il default e'
`backups/<progetto>_YYYY-mm-dd__HH-MM-SS.sql.gz` (`.gz` viene aggiunto se lo
ometti). `backups/` e' gitignorata.

**Quiescenza dello stack.** Un restore elimina e ricrea i database, cosa che le
connessioni aperte impedirebbero: per questo di default ferma tutti i servizi
tranne il database e li riavvia al termine. `--online` salta questo passo —
utile quando nessuno tiene connessioni aperte, a rischio di far fallire il
restore.

Un backup gira invece sullo stack attivo. Con `--offline` ferma prima gli altri
servizi, per un dump preso senza scritture in corso. In entrambi i casi i
container vengono riavviati al termine, anche se il comando fallisce o viene
interrotto.

Il restore sostituisce il contenuto del cluster, quindi chiede conferma;
`--yes` la salta.

```bash
$ ./gnrdev backup sandbox
==> dumping the sandbox cluster
==> written backups/sandbox_2026-09-23__10-03-13.sql.gz (1.1M)

$ ./gnrdev backup sandbox --offline
==> stopping:app
==> dumping the sandbox cluster
==> restarting:app
==> written backups/sandbox_2026-09-23__10-05-26.sql.gz (1.1M)

$ ./gnrdev restore sandbox backups/sandbox_2026-09-23__10-03-13.sql.gz --yes
==> stopping:app
==> restoring into sandbox
==> restarting:app
==> restore complete
```

### Rimuovere un progetto

```bash
./gnrdev rm <progetto>                 # chiede conferma
./gnrdev rm <progetto> --keep-env      # rimuove i container, tiene la config
./gnrdev rm <progetto> --yes           # senza conferma
```

Elenca cosa sparira' prima di chiedere. Il volume del database e' incluso,
quindi schema e dati vanno persi; i sorgenti sull'host non vengono mai toccati.
Con `--keep-env` la configurazione sopravvive e `up` ricrea lo stack da zero.

## Porte

Due range paralleli, stesso offset per progetto, cosi' le ultime cifre legano
la porta web e quella di debug dello stesso progetto:

| Progetto | Web | Debug |
|---|---|---|
| primo | 9000 | 9100 |
| secondo | 9001 | 9101 |
| terzo | 9002 | 9102 |

Le basi sono `GNR_PORT_WEB_BASE` / `GNR_PORT_DEBUG_BASE` in `.env`. `new`
sceglie il primo offset libero in *entrambi* i range, saltando le porte gia'
assegnate ad altri progetti o occupate sull'host. Sono valori ordinari nel
`.env` del progetto e si possono modificare a mano.

La porta web e' **identica dentro e fuori dal container** — il server viene
avviato con `-p ${GNR_PORT_WEB}` e mappato 1:1 — quindi l'URL che Genropy
scrive nei log (`Connect at http://127.0.0.1:9000`) e' quello che funziona
davvero.

`GNR_PORT_DB=0` lascia PostgreSQL non esposto; imposta una porta per
raggiungerlo con un client esterno.

## Far dialogare i progetti

Di default ogni stack e' isolato sulla propria rete. Per farli comunicare,
mettili su una rete Docker condivisa:

```bash
./gnrdev new sandbox sandboxpg --network gnrdev # crea la rete se non esiste
./gnrdev up sandbox
```

`new --network` scrive `GNR_NETWORK` nel `.env` del progetto e crea la rete
Docker se non c'e' ancora, quindi non serve un passo di setup separato.

Per un progetto esistente, imposta `GNR_NETWORK` nel suo `.env` oppure forza una
rete per un singolo avvio — il `.env` resta invariato:

```bash
./gnrdev up sandbox --network gnrdev
```

Su quella rete ogni progetto risponde a due alias stabili, sulle porte
**interne**: non serve pubblicare nulla in piu' sull'host.

| Alias | Raggiunge |
|---|---|
| `<progetto>` | il container app, su `GNR_PORT_WEB` |
| `<progetto>-db` | il suo database, su 5432 |

Quindi da `edodevel` l'API di sandbox e' `http://sandbox:9000` e il suo database
`sandbox-db:5432`. L'accesso dall'host tramite la porta pubblicata continua a
funzionare come prima.

```bash
$ ./gnrdev network list
NETWORK                  STATUS       PROJECTS
gnrdev                   available    edodevel, sandbox
isolated: infoit

$ ./gnrdev network create gnrdev      # serve solo per una rete che nessun progetto dichiara
$ ./gnrdev network rm gnrdev          # stacca prima i progetti
```

Anche `gnrdev ls` mostra la rete di ogni progetto:

```
PROJECT            INSTANCE         PORT   NETWORK        STATUS    DEBUG  URL
edodevel           edodevel         9001   gnrdev         running   -      http://localhost:9001
sandbox            sandboxpg        9000   gnrdev         running   -      http://localhost:9000
```

Lasciare `GNR_NETWORK` vuoto mantiene il progetto isolato.

## Debug remoto (GNR_PORT_DEBUG)

`GNR_PORT_DEBUG` serve solo al debug da IDE. Se non attacchi mai un debugger la
porta resta inutilizzata e puoi toglierla dal `.env` del progetto.

Esiste come porta separata per come il framework avvia debugpy:
`debugpy.listen(("localhost", 5678))` fa bind sul loopback del container, quindi
pubblicare direttamente la 5678 non la renderebbe raggiungibile dall'host. Un
ponte `socat` nel container inoltra 5679 → 5678, e `GNR_PORT_DEBUG` mappa quella
5679.

### Quando conviene

Quando il ciclo print-and-reload smette di ripagare: seguire passo passo un
`@public_method` invocato dal client, ispezionare un Bag la cui struttura non si
capisce dai log, intercettare un'eccezione sollevata dentro un trigger di
tabella o in un upgrade di `gnr db migrate`, o capire perche' una risorsa viene
risolta nel package sbagliato tra progetti diversi. Per controllare al volo un
valore, una riga di log e' piu' rapida.

### Come si usa

```bash
./gnrdev debug sandbox
```

Ferma il server sotto supervisor, avvia il ponte socat e riavvia
`gnr web serve` con `--debugpy` sulla stessa porta web. Poi attacca l'IDE alla
porta di debug del progetto. Finche' il progetto gira cosi', `gnrdev ls` mostra
la porta nella colonna DEBUG, e `./gnrdev restart <progetto>` lo riporta sotto
supervisor.

`launch.json` per VS Code — il secondo mapping serve solo se vuoi entrare anche
nel codice del framework:

```json
{
  "type": "debugpy", "request": "attach",
  "connect": { "host": "localhost", "port": 9100 },
  "pathMappings": [
    { "localRoot": "${workspaceFolder}",
      "remoteRoot": "/home/genro/genropy_projects/sandbox" },
    { "localRoot": "/path/to/genropy",
      "remoteRoot": "/home/genro/genropy" }
  ]
}
```

PyCharm: *Attach to process* → *Python Debug Server*, stessi host e porta, con
mapping equivalenti.

Due cose da sapere:

- **Durante il debug l'autoreload e' disattivato.** Lo disabilita il framework
  sotto `--debugpy` (il reloader forka e perderebbe l'attach). Dopo le modifiche,
  `./gnrdev restart <progetto>` riporta il server supervisato con reload attivo.
- Il debugger non ti aspetta. Attacca prima di scatenare il codice che ti
  interessa, oppure metti il breakpoint e riproduci dopo.

## Versione del framework

`GENROPY_TAG` in `.env` fissa il tag dell'immagine ufficiale (`latest`,
`develop`, o una versione come `26.05.05`). Dopo averlo cambiato:
`./gnrdev rebuild <progetto>`.

Per lavorare sul framework stesso, o per usare un branch/commit specifico:

```bash
./gnrdev up <progetto> --framework-src
```

Monta il checkout indicato da `HOST_GENROPY`, opzionalmente posizionato su
`GNR_FRAMEWORK_REF`, e lo installa in editable mode: le modifiche al framework
hanno effetto immediato. Da' accesso anche alle versioni di dojo assenti
nell'immagine ufficiale.

## Dipendenze cross-progetto

Si dichiarano normalmente nella configurazione dell'istanza con
`pkgcode="progetto:package"`. Gli alberi `genropy_projects` e
`gnrextra_projects` sono montati interi, quindi di norma funziona senza
configurazione aggiuntiva.

`GNR_DEP_PROJECTS` nel `.env` del progetto documenta la relazione; le dipendenze
Python vengono risolte da `gnr app checkdep`, eseguito all'avvio del container.

Un'insidia da conoscere: `project_path()` restituisce la *prima* directory che
corrisponde al nome del progetto tra i root `<projects>` dichiarati. Se lo stesso
nome esiste in piu' alberi, l'ordine decide chi vince — e un package puo'
risultare mancante pur essendo su disco.

## Struttura

```
compose.project.yaml     stack per progetto (unico file parametrico)
compose.framework.yaml   override per il framework da sorgenti
compose.network.yaml     override applicato quando GNR_NETWORK e' valorizzata
docker/                  Dockerfile di sviluppo, entrypoint, config supervisor
gnrfolder/               configurazione .gnr, montata read-only nei container
projects/<nome>.env      configurazione per progetto (non versionata)
gnrdev                   wrapper dei comandi
```

Note implementative e vincoli del framework: `docs/troubleshooting.md`.

## Licenza

Copyright (c) 2026 Edoardo Federici

Distribuito con licenza Apache License 2.0 — la stessa che Softwell adotta per
i repository Genropy piu' recenti. Vedi [LICENSE](LICENSE).
