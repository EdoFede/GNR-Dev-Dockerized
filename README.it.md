# GenroPy Dev Dockerized

_Un ambiente di sviluppo dockerizzato per progetti Genropy_

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
├── db           postgres, volume dedicato
├── pgclient     una tantum: copia psql/pg_dump/pg_restore per app
├── app          gnr web daemon + gnr web serve (stesso container)
└── debugbridge  solo durante il debug (vedi Debug remoto)
```

Non viene costruita nessuna immagine. `app` usa l'immagine ufficiale
`ghcr.io/genropy/genropy` cosi' com'e': entrypoint e configurazione di
supervisor sono montati da `docker/`, le dipendenze Python finiscono in un
volume per progetto, e i pochi strumenti che mancano all'immagine arrivano da
altre immagini ufficiali. I progetti sullo stesso tag del framework condividono
un'unica immagine su disco.

Il daemon e il web server condividono il container per necessita': il client
del site register verifica il PID del site daemon con `psutil.pid_exists()`,
che e' locale al PID namespace. Ogni progetto ha il proprio daemon grazie a
`<sitedaemon/>`, quindi non esiste un daemon condiviso che accoppi i progetti.

## Setup

```bash
./gnrdev setup
```

`setup` scrive il `.env` globale passo passo: la radice dei progetti, le
directory opzionali di gnrextra e dei sorgenti Genropy, `HOST_UID`/`HOST_GID`
(precompilati con l'utente corrente), il tag di default dell'immagine
(`latest`) e le tre porte base. Rilancialo per cambiare la configurazione: i
percorsi attuali vengono proposti come default e il file precedente resta in
`.env.bak`. In alternativa si puo' copiare `.env.example` in `.env` e
modificarlo a mano.

Senza `HOST_GNREXTRA` al suo posto viene montato un volume vuoto;
`HOST_GENROPY` serve solo ai progetti in modalita' framework-local.

### Lanciare gnrdev da qualunque directory

`gnrdev` lavora sulla directory indicata da `GNRDEV_ROOT_DIR`. L'ultimo passo di
`setup` propone di aggiungerla al profilo della shell (`~/.zshrc`;
`~/.bash_profile` per bash su macOS, `~/.bashrc` su Linux), oppure stampa la
riga da aggiungere a mano:

```bash
export GNRDEV_ROOT_DIR="/percorso/di/gnr-dev-dockerized"
```

Serve un nuovo terminale (o un `source` del profilo) perche' abbia effetto. Con
la variabile impostata `gnrdev` si puo' lanciare da qualunque directory, anche
tramite un symlink nel `PATH`:

```bash
ln -s "$GNRDEV_ROOT_DIR/gnrdev" ~/.local/bin/gnrdev
```

Senza la variabile `gnrdev` usa la directory in cui si trova: `./gnrdev` dal
repository funziona normalmente, lanciarlo per percorso da altrove funziona con
un warning, un symlink si ferma con un errore (i symlink non vengono seguiti).

I percorsi passati da riga di comando (`setup`, `new --projects-dir`, il file di
`backup` e `restore`) sono relativi alla directory in cui ti trovi, non al
repository.

`HOST_UID`/`HOST_GID` devono corrispondere a `id -u` / `id -g` (se mancano,
`gnrdev` usa l'utente corrente). L'app gira con quell'uid/gid: l'entrypoint
parte come root, aggiunge un utente `gnrdev` con quegli id e passa a lui. Su
Linux e' questo che mantiene scrivibile la directory dell'istanza e intestati a
te i file che il framework ci scrive (file temporanei, stato del sito). Su macOS
il runtime rimappa comunque l'ownership dei bind mount, quindi i valori contano
meno.

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
PROJECT          INSTANCE        STATUS    WEB PORT  DEBUG PORT DB PORT  NETWORK      FRAMEWORK              URL
edodevel         edodevel        running   9001      -          9201     -            image (latest)         http://localhost:9001
sandbox          sandboxpg       running   9000      -          9200     -            local (master)         http://localhost:9000
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
./gnrdev pull <progetto>               # aggiorna l'immagine ufficiale (poi up)
```

`logs`, `shell` e `restart` accettano anche `<progetto>.<servizio>` per agire su
un singolo container:

```bash
./gnrdev logs sandbox.app -f           # solo l'applicazione
./gnrdev logs sandbox.db               # solo il database
./gnrdev shell sandbox.db              # shell nel container postgres
./gnrdev restart sandbox.db            # riavvia solo il database
```

Servizi: `app`, `db` (piu' `pgclient`, `debugbridge`, `init-fwgit` e `fwgit`).

I container hanno hostname uguale al nome del container, quindi il prompt dice
dove ti trovi: `gnrdev@gnr-sandbox-app`. `shell`, `gnr`, `dbcheck` e
`dbmigrate` girano con l'utente dell'app, mai come root.

### Backup e restore

```bash
./gnrdev backup <progetto> [file] [--offline]
./gnrdev restore <progetto> [file] [--yes] [--online]
./gnrdev backups                             # elenca quelli gia' fatti
```

Un backup e' un singolo `pg_dumpall` compresso, quindi copre tutti i database
del cluster del progetto — cosa che conta per le istanze multidb, dove ogni
store e' un database a se'. Ruoli e database di servizio vengono filtrati: il
cluster appartiene al progetto e il suo ruolo esiste gia', quindi riapplicarli
produrrebbe solo errori durante il restore.

Un nome file e' relativo alla directory in cui ti trovi: `gnrdev backup sandbox
bck.sql.gz` lanciato da `~/Downloads` scrive `~/Downloads/bck.sql.gz`. Senza nome
file il backup finisce in `backups/<progetto>_YYYY-mm-dd__HH-MM-SS.sql.gz` nel
repository, e viene stampato il percorso completo (`.gz` viene aggiunto se lo
ometti). `backups/` e' gitignorata.

`restore` senza file elenca i backup di quel progetto presenti in `backups/`,
ordinati per nome (quindi per data), e chiede il numero di quello da
ripristinare.

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
==> written /percorso/di/gnr-dev-dockerized/backups/sandbox_2026-09-23__10-03-13.sql.gz (1.1M)

$ ./gnrdev backup sandbox --offline
==> stopping:app
==> dumping the sandbox cluster
==> restarting:app
==> written /percorso/di/gnr-dev-dockerized/backups/sandbox_2026-09-23__10-05-26.sql.gz (1.1M)

$ ./gnrdev restore sandbox
Backups of sandbox in /percorso/di/gnr-dev-dockerized/backups/:
  1  sandbox_2026-09-23__10-03-13.sql.gz            1.1M
  2  sandbox_2026-09-23__10-05-26.sql.gz            1.1M
Backup to restore [1-2]: 1
Restoring /percorso/di/gnr-dev-dockerized/backups/sandbox_2026-09-23__10-03-13.sql.gz into sandbox.
The current content of the cluster will be replaced.
Proceed? [y/N] y
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

Tre range paralleli, stesso offset per progetto, cosi' le ultime cifre legano
le porte web, debug e database dello stesso progetto:

| Progetto | Web | Debug | Database |
|---|---|---|---|
| primo | 9000 | 9100 | 9200 |
| secondo | 9001 | 9101 | 9201 |
| terzo | 9002 | 9102 | 9202 |

Le basi sono `GNR_PORT_WEB_BASE` / `GNR_PORT_DEBUG_BASE` / `GNR_PORT_DB_BASE` in
`.env`. `new` sceglie il primo offset libero in *tutti* i range, saltando le
porte gia' assegnate ad altri progetti o occupate sull'host. Sono valori ordinari nel
`.env` del progetto e si possono modificare a mano.

La porta web e' **identica dentro e fuori dal container** — il server viene
avviato con `-p ${GNR_PORT_WEB}` e mappato 1:1 — quindi l'URL che Genropy
scrive nei log (`Connect at http://127.0.0.1:9000`) e' quello che funziona
davvero.

PostgreSQL viene pubblicato per essere raggiungibile da client esterni; con
`GNR_PORT_DB=0` nel `.env` del progetto resta non pubblicato.

L'immagine del database e' `postgres:18` di default (`POSTGRES_TAG` per
progetto). Le versioni precedenti tengono i dati in un percorso diverso:
`gnrdev` lo gestisce per qualsiasi tag inferiore a 18 (vedi
`docs/troubleshooting.md`).

Il framework stesso usa `psql`, `pg_dump` e `pg_restore`, che l'immagine
ufficiale non ha. Il servizio una tantum `pgclient` li copia, insieme alla loro
`libpq`, dall'immagine postgres del progetto: nessun download in piu', e il
client ha sempre la stessa versione del server.

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
PROJECT          INSTANCE        STATUS    WEB PORT  DEBUG PORT DB PORT  NETWORK      FRAMEWORK              URL
edodevel         edodevel        running   9001      -          9201     gnrdev       image (latest)         http://localhost:9001
sandbox          sandboxpg       running   9000      -          9200     gnrdev       git develop            http://localhost:9000
```

Lasciare `GNR_NETWORK` vuoto mantiene il progetto isolato.

## Debug remoto (GNR_PORT_DEBUG)

`GNR_PORT_DEBUG` serve solo al debug da IDE. Se non attacchi mai un debugger la
porta resta inutilizzata e puoi toglierla dal `.env` del progetto.

Esiste come porta separata per come il framework avvia debugpy:
`debugpy.listen(("localhost", 5678))` fa bind sul loopback del container, quindi
pubblicare direttamente la 5678 non la renderebbe raggiungibile dall'host. Un
sidecar `socat` (`debugbridge`) condivide il network namespace dell'app, quindi
vede quel loopback, e inoltra 5679 → 5678; `GNR_PORT_DEBUG` mappa quella 5679.
Il sidecar gira solo durante il debug.

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

Ferma il server sotto supervisor, avvia il sidecar `debugbridge` e riavvia
`gnr web serve` con `--debugpy` sulla stessa porta web. Poi attacca l'IDE alla
porta di debug del progetto. Finche' il progetto gira cosi', `gnrdev ls` mostra
la porta nella colonna DEBUG, e `./gnrdev restart <progetto>` lo riporta sotto
supervisor e rimuove il sidecar.

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

Di default il framework viene dall'immagine ufficiale, al tag indicato da
`GENROPY_TAG` in `.env` (`latest`, `develop`, o una versione come `26.05.05`).
Un tag nuovo viene scaricato dal primo `up`. Un tag mobile come `latest` non si
aggiorna da solo: `./gnrdev pull <progetto>`, poi `up`. In entrambi i casi le
dipendenze Python vengono ricontrollate al successivo avvio.

Esistono altre due modalita', e un progetto puo' essere fissato su una di esse
gia' alla creazione:

```bash
./gnrdev new <progetto> --framework-local        # il checkout su questo host
./gnrdev new <progetto> --framework-git develop  # un clone di quel branch/commit
```

**`--framework-local`** bind-monta `HOST_GENROPY`: le modifiche al framework
hanno effetto immediato (autoreload compreso). Il checkout dell'host
viene usato com'e', nessun comando git lo tocca. Da' accesso anche alle versioni
di dojo assenti nell'immagine ufficiale.

**`--framework-git <ref>`** tiene un clone del repository ufficiale in un volume
per progetto, isolato dall'host. Il ref viene fetchato e ri-checkoutato **a ogni
avvio**, quindi il container resta allineato a quanto pubblicato nel repository,
e due progetti possono stare su ref diversi senza conflitti. Con
`GNR_FRAMEWORK_REPO` nel `.env` del progetto si punta a un altro repository.

Entrambe le modalita' usano la stessa immagine ufficiale. Il checkout viene
montato sopra `/home/genro/genropy`, dove `environment.xml` cerca gia' gli
asset statici, e il suo `gnrpy/` va in testa al `PYTHONPATH`, davanti alla copia
installata nell'immagine. Viene anche installato in editable mode nel volume
Python del progetto, cosi' arrivano le dipendenze che dichiara; l'installazione
si ripete quando cambia il suo `pyproject.toml` e viene rimossa quando il
progetto torna all'immagine. L'entrypoint fallisce esplicitamente se il
checkout non e' quello realmente importato.

L'installazione editable lascia un `genropy.egg-info` in `gnrpy/` del checkout;
e' ignorato da git.

`up` cambia la modalita' per un singolo avvio, senza toccare il `.env`:

```bash
./gnrdev up <progetto> --framework-local
./gnrdev up <progetto> --framework-git 26.05.05
./gnrdev up <progetto> --framework-image     # torna all'immagine ufficiale
```

L'avvio successivo senza flag torna a quanto dice il `.env`.

`gnrdev ls` mostra nella colonna FRAMEWORK cosa sta **effettivamente girando**
in ogni progetto — `image (<tag>)`, `local (<branch>)` o `git <ref>` — letto dal
container. Il marcatore `[OVR]` segnala che il container non corrisponde al
`.env` del progetto, cioe' e' stato avviato con uno dei flag qui sopra:

```
sandbox          ...   git master [OVR]       http://localhost:9000
```
## Dipendenze cross-progetto

Si dichiarano normalmente nella configurazione dell'istanza con
`pkgcode="progetto:package"`. Gli alberi `genropy_projects` e
`gnrextra_projects` sono montati interi, quindi di norma funziona senza
configurazione aggiuntiva.

Di default quegli alberi sono `HOST_PROJECTS` e `HOST_GNREXTRA` del `.env`
globale. Un progetto puo' montarne altri impostando `GNR_PROJECTS_DIR` e
`GNR_EXTRA_DIR` nel proprio `.env` (percorsi assoluti; vuoto = il default),
oppure alla creazione:

```bash
./gnrdev new helloworld --projects-dir tests/genropy_projects
```

`GNR_DEP_PROJECTS` nel `.env` del progetto documenta la relazione; le dipendenze
Python vengono risolte da `gnr app checkdep`, eseguito all'avvio del container.

Un'insidia da conoscere: `project_path()` restituisce la *prima* directory che
corrisponde al nome del progetto tra i root `<projects>` dichiarati. Se lo stesso
nome esiste in piu' alberi, l'ordine decide chi vince — e un package puo'
risultare mancante pur essendo su disco.

## Struttura

```
compose.project.yaml     stack per progetto (unico file parametrico)
compose.framework-*.yaml override per il framework da sorgenti (local, git)
compose.network.yaml     override applicato quando GNR_NETWORK e' valorizzata
compose.nodb.yaml        override applicato quando GNR_PORT_DB=0
compose.pg-legacy.yaml   override applicato quando POSTGRES_TAG e' inferiore a 18
docker/                  entrypoint e config supervisor, montati in app
gnrfolder/               configurazione .gnr, montata read-only nei container
projects/<nome>.env      configurazione per progetto (non versionata)
gnrdev                   wrapper dei comandi
```

Note implementative e vincoli del framework: `docs/troubleshooting.md`.

## Licenza

Copyright (c) 2026 Edoardo Federici

Distribuito con licenza Apache License 2.0 — la stessa che Softwell adotta per
i repository Genropy piu' recenti. Vedi [LICENSE](LICENSE).
