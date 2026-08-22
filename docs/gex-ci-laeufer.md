# Eigener GitHub-Actions-Laeufer auf gex44

Betriebsdoku fuer die selbstgehosteten CI-Laeufer auf gex44.
Aufgesetzt am 21.08.2026, damit die CI-Laeufe der swippipp-Repos nicht mehr das gehostete Minuten-Kontingent verbrennen.
Die Umstellung der einzelnen Repos gehoert nicht hierher, sondern in [`gex-ci-uebergabe-phase2.md`](gex-ci-uebergabe-phase2.md).

## Kurzfassung

15 ephemere Laeufer-Plaetze auf 14 Repos unter dem Label `gex`, siehe [Plaetze](#plaetze) fuer die vollstaendige Liste.
Sie laufen als unprivilegierter Nutzer `ghrunner` in rootless-Podman-Containern, teilen sich hoechstens 8 Kerne und 16 GB, und weichen der Produktion bei Knappheit aus.
Auf gex liegt **kein dauerhaftes GitHub-Geheimnis**; ein Relais auf dem Laptop des Kapitaens reicht alle 30 Minuten ein kurzlebiges Registrierungs-Token durch.

## Warum der Zuschnitt so ist

### swippipp ist ein Nutzerkonto, keine Organisation

`gh api user` liefert `type: User`, `gh api user/orgs` liefert `[]`.
GitHub bietet selbstgehostete Laeufer nur auf Organisations- und auf Repo-Ebene an; persoenliche Konten haben keine Laeufergruppen.
Es gibt also keinen einen Laeufer fuer alle Repos - **jedes Repo braucht seine eigene Registrierung**, und ein registrierter Laeufer bedient ausschliesslich sein Repo.
"Zwei Laeufer parallel" heisst deshalb: zwei Plaetze fuer ein Repo, oder je einer fuer zwei Repos.

### Rootless Podman statt Docker

Ubuntus `docker.io`-Paket liefert `dockerd-rootless.sh` nicht mit, und `docker-ce-rootless-extras` gibt es in Ubuntus Quellen nicht.
Rootless Docker haette geheissen, Dockers Upstream-Repo neben die Distributions-Docker zu haengen, die alle 25 Produktionscontainer auf gex faehrt - der invasivste denkbare Eingriff auf genau der Maschine, die unbehelligt bleiben soll.

Podman kommt vollstaendig aus Ubuntus eigenen Quellen, ist daemonlos (kein zweiter langlebiger Dienst), hat einen eigenen Bildspeicher unter `~ghrunner/.local/share/containers`, und die noetigen AppArmor-Profile (`/etc/apparmor.d/podman`, `/etc/apparmor.d/rootlesskit`) liegen auf Ubuntu 24.04 bereits vor.
`kernel.apparmor_restrict_unprivileged_userns=1` bleibt unveraendert an - die Haerte des Wirts wurde nirgends gelockert.

### Kein Docker-in-Docker, kein Socket

Keine der CI-Dateien benutzt `container:`, `services:` oder ein Docker-Kommando (geprueft am 21.08.2026 ueber lensclash, SnackSuite, LensclashDB, GEX_GATEWAY).
Also ist die Faehigkeit **abwesend**, nicht bloss ungenutzt: kein Docker-Client im Bild, kein Socket durchgereicht, `ghrunner` nicht in der Gruppe `docker`.
Braucht ein kuenftiger Auftrag Container, ist das eine eigene Entscheidung mit eigener Abwaegung.

## Bestandteile

Auf **gex44**:

| Ort | Inhalt |
|---|---|
| Nutzer `ghrunner` (uid 1001) | unprivilegiert, `nologin`, nicht in `docker`, kein sudo, subuid/subgid 165536:65536, Linger an |
| `/etc/gh-runner/repos` | Positivliste der Repos, die einen Laeufer bekommen duerfen (0640 root:ghrunner) |
| `/etc/gh-runner/token-<repo>` | kurzlebiges Registrierungs-Token, Zeile 1 Token, Zeile 2 Ablauf (0640 root:ghrunner) |
| `/opt/gh-runner/supervise.sh` | startet genau einen ephemeren Laeufer-Container und endet dann |
| `/home/ghrunner/image/` | `Containerfile` + `entrypoint.sh`, aus denen `localhost/gh-runner:base` gebaut wird |
| `~ghrunner/.config/systemd/user/gh-runner.slice` | aggregierter CPU-/RAM-Deckel |
| `~ghrunner/.config/systemd/user/gh-runner@.service` | eine Instanz je Platz, Instanzname `<repo>-<slot>` |

Auf dem **Laptop des Kapitaens**:

| Ort | Inhalt |
|---|---|
| `~/.local/bin/gh-runner-token-relay.sh` | muenzt Token und reicht sie an gex durch |
| `~/.config/systemd/user/gh-runner-token-relay.{service,timer}` | alle 30 Minuten, `Persistent=true` |

Wortgleiche Kopien aller Dateien liegen in [`examples/gex-ci-runner/`](examples/gex-ci-runner/).
Sie liegen bewusst **nicht** unter `bin/`: das ist Flotten-Werkzeug fuer alle firstmate-Nutzer, dies hier ist wirtsspezifische Betriebstechnik fuer genau eine Maschine.

## Plaetze

Stand 22.08.2026, gegen `/etc/gh-runner/repos` und `gh api repos/swippipp/<repo>/actions/runners` auf gex geprueft.
Alle Plaetze `enabled`, `Restart=always`, bei GitHub `online`, `busy=false`.

| Repo | Plaetze | Seit | Bemerkung |
|---|---|---|---|
| `lensclash` | `lensclash-1`, `lensclash-2` | 21.08.2026 | Workflow bereits auf `gex` umgestellt (Repo-Bahn). |
| `GEX_GATEWAY` | `GEX_GATEWAY-1` | 21.08.2026 | |
| `LensclashDB` | `LensclashDB-1` | 21.08.2026 | |
| `testlab` | `testlab-1` | 21.08.2026, seit 22.08.2026 dauerhaft | Workflow bereits auf `gex` umgestellt (Repo-Bahn). Stand vorher aus, s. [Ein Repo anbinden](#ein-repo-anbinden). |
| `SnackSuite` | `SnackSuite-1` | 22.08.2026 | Bild fehlen noch die Playwright/Chromium-Systempakete, s. [Grenzen](#grenzen-und-offene-punkte). |
| `Quiz-Web` | `Quiz-Web-1` | 22.08.2026 | |
| `HPlan` | `HPlan-1` | 22.08.2026 | Nicht Teil der urspruenglichen Zwoelf-Analyse in der Uebergabe; auf ausdruecklichen Auftrag ergaenzt (aktive Lieferstrasse). |
| `Strickapp` | `Strickapp-1` | 22.08.2026 | Dito HPlan. |
| `Bietkompass` | `Bietkompass-1` | 22.08.2026 | Bild fehlt noch `poppler-utils`, s. [Grenzen](#grenzen-und-offene-punkte). |
| `Homepage` | `Homepage-1` | 22.08.2026 | |
| `Lernplattform` | `Lernplattform-1` | 22.08.2026 | |
| `wimmel` | `wimmel-1` | 22.08.2026 | |
| `rag-digital` | `rag-digital-1` | 22.08.2026 | |
| `trooper_ai` | `trooper_ai-1` | 22.08.2026 | |

Ein Platz allein legt `runs-on` im Repo nicht um - das bleibt Sache der jeweiligen Bahn, siehe [Uebergabe](gex-ci-uebergabe-phase2.md).
`HPlan` und `Strickapp` sind private swippipp-Repos ausserhalb der urspruenglich analysierten zwoelf; ihre Plaetze folgen demselben Verfahren, aber ihr Verbrauch und ihre Werkzeuganforderungen sind noch nicht wie bei den zwoelf durchgeprueft - vor der Umstellung dort gilt dieselbe Vorsicht wie in der Uebergabe beschrieben.

## Das Relais - warum auf gex kein Dauergeheimnis liegt

Ein ephemerer Laeufer meldet sich nach jedem Auftrag ab und braucht fuer die naechste Registrierung ein frisches Token.
Der naheliegende Weg waere ein PAT oder ein GitHub-App-Schluessel auf gex - ein dauerhaftes Geheimnis auf einer Maschine, die ins offene Netz haengt.

Stattdessen:

1. Der Laptop hat die funktionierende `gh`-Anmeldung. Gemessen: `gh` liefert auch ohne DBus/Session-Bus, ein unbeaufsichtigter Timer kann also muenzen.
2. Ein Registrierungs-Token ist **innerhalb seiner Stunde mehrfach verwendbar**. Gemessen am 21.08.2026: zwei Laeufer aus einem einzigen Token registriert.
3. Alle 30 Minuten muenzt der Laptop ein neues Token je Repo der Positivliste und legt es auf gex ab. gex haelt damit immer ein Token mit mindestens halber Restlaufzeit.

Auf gex liegt also nie mehr als ein Geheimnis, das sich innerhalb einer Stunde von selbst entwertet und ausschliesslich Laeufer auf Repos der Positivliste registrieren kann.

**Richtung:** Der Laptop schiebt, gex zieht nicht.
gex kann den Laptop nicht erreichen - er haengt hinter NAT, hat kein sshd, und Tailscale ist abgemeldet und auf gex nicht installiert.

**Wenn der Laptop schlaeft:** Bereits registrierte Laeufer bedienen weiter (ein untaetiger Laeufer braucht kein Token), und das zwischengespeicherte Token bleibt bis zu einer Stunde brauchbar.
Danach stoppen Registrierungen, und Auftraege reihen sich bei GitHub ein (dort bis zu 24 Stunden gehalten); nichts faellt um.
Das faellt kaum ins Gewicht: **kein einziges Repo hat `schedule:`, `workflow_dispatch:` oder `repository_dispatch:`** - jeder Lauf kommt von einem Push, und alle Bahnen pushen von genau diesem Laptop.
Das reale Restrisiko ist ein Push von einer anderen Maschine, waehrend der Laptop schlaeft.

Der Relais-Skript verweigert das Muenzen fuer jedes Repo, das nicht nachweislich privat ist; `supervise.sh` auf gex prueft die Positivliste ein zweites Mal.
Ein selbstgehosteter Laeufer an einem oeffentlichen Repo wuerde fremden PR-Code ausfuehren - beide Haelften dieser Sperre sind unabhaengig voneinander wirksam.

## Deckel

Der Deckel ist **aggregiert**, nicht je Laeufer.
Zwei Laeufer mit je 8 Kernen waeren 16 der 20 Kerne von gex, auf der 25 Produktionscontainer laufen; der Zweck ("CI verdraengt niemals die Produktion") haette die woertliche Lesart nicht ueberlebt.

`gh-runner.slice` setzt: `CPUQuota=800%`, `CPUWeight=20`, `MemoryHigh=12G`, `MemoryMax=16G`, `IOWeight=20`, `TasksMax=8192`.
`CPUWeight=20` gegen den Standard 100 ist die zweite Haelfte: auch innerhalb der Quote gewinnt die Produktion jede umkaempfte Zuteilung.
Je Container zusaetzlich `--cpus=8 --memory=16g --pids-limit=4096` als Sicherung.

Dienst **und** Container haengen beide unter der Slice - nachgesehen:

```
/user.slice/user-1001.slice/user@1001.service/gh.slice/gh-runner.slice/gh-runner@lensclash-1.service
/user.slice/user-1001.slice/user@1001.service/gh.slice/gh-runner.slice/libpod-<id>.scope
```

`cpuset` ist auf gex nicht an `user.slice` delegiert, feste Kernbindung geht also nicht - der Deckel ist eine CFS-Quote, kein Pinning.
Nebenwirkung: der Container sieht weiterhin `nproc=20`. Werkzeuge, die daraus ihre Parallelitaet ableiten, starten 20 Arbeiter gegen ein 8-Kern-Budget und werden gedrosselt. Das ist ineffizient, aber ungefaehrlich.

## Belege (21.08.2026)

### Der Testlauf

`lensclash`, Wegwerf-Zweig mit geaendertem `runs-on`, Entwurfs-PR als Ausloeser, danach beides entfernt.
[Lauf 32484742583](https://github.com/swippipp/lensclash/actions/runs/32484742583): **gruen, alle drei Jobs.**

| Job | gehostet (Schnitt) | auf gex | |
|---|---:|---:|---|
| `gates` (3x npm ci, Typechecks, hardhat, expo export) | 171 s | **119 s** | 1,44x schneller |
| `docs-contract` | 72 s | 75 s | gleich |
| `citation-anchors` | 34 s | 50 s | langsamer, s. u. |
| **Gesamtlauf** | **174 s** (n=14, 153-211 s) | **146 s** | 16 % schneller |

`citation-anchors` ist langsamer, weil es auf gex einen `setup-node`-Schritt braucht, den es gehostet nicht brauchte - der Download kostet die Differenz.
Der Gesamtlauf gewinnt trotzdem, obwohl gex nur zwei Plaetze hat, wo der gehostete Laeufer drei parallele Jobs zulaesst, und obwohl jeder Lauf mit kaltem npm-Cache startet.

### Die Deckel greifen

Waehrend des echten CI-Laufs: `nr_throttled 73`, `throttled_usec 9535003` - die Quote hat wirklich gebissen.
Spitzenverbrauch 7,1 GB gegen 16 GB Deckel.

Gegenprobe mit 20 Brenner-Threads gegen einen 8-Kern-Deckel, 20 Sekunden Wanduhr:

```
CPU-Sekunden in 20s Wanduhr: 160s   (8 Kerne x 20s - punktgenau, nicht 20 Kerne x 20s)
nr_throttled 388  throttled_usec 89451622
```

### Die Produktion blieb unbeeintraechtigt

| | vorher (14:27) | nachher (15:05) |
|---|---|---|
| Container | 25 | 25 |
| ungesund | keiner | keiner |
| neu gestartet / beendet | - | keiner |
| Speicher belegt | 15 GB | 15 GB |

Waehrend des CI-Laufs stieg die Last auf hoechstens 2,13 (20 Kerne).
Weder Caddy noch DNS noch ein Container eines anderen Dienstes wurde angefasst.

### Die Sicherheitsauflagen

Im laufenden Laeufer-Container nachgesehen:

```
Nutzer:            uid=1001(runner)          -- nicht root
Faehigkeiten:      CapEff: 0000000000000000  -- keine einzige
GPU-Geraete:       /dev/nvidia*: nicht vorhanden
nvidia-smi:        nicht vorhanden
docker-Socket:     /var/run/docker.sock: nicht vorhanden
docker-Client:     nicht vorhanden
podman im Bild:    nicht vorhanden
Loopback des Wirts: nicht erreichbar
cpu.max=800000 100000   memory.max=17179869184
```

### Ephemeralitaet

`NRestarts` des Dienstes steigt mit jedem bedienten Auftrag; jeder Neustart registriert einen frischen Laeufer mit frischem Arbeitsverzeichnis.
Nach dem Auftrag bleibt kein Container zurueck (`--rm`), und kein Zustand ueberlebt.

## Was dem gehosteten Bild fehlt

GitHubs `ubuntu-latest` bringt hunderte vorinstallierter Werkzeuge mit; dieses Bild bringt mit, was unsere Workflows wirklich brauchen.
**Ein Workflow, der sich still auf eine Dreingabe des gehosteten Bildes verlassen hat, faellt hier mit `command not found` um.**
Im Testlauf traf das dreimal zu: `shellcheck`, `python` (Ubuntu hat nur `python3`) und `node`.

Zwei Wege, und die Wahl ist keine Geschmacksfrage:

* **Der Workflow holt sich, was er braucht** - richtig, wenn ein Setup-Schritt existiert (`setup-node`, `setup-uv`, `setup-python`). Das macht die Abhaengigkeit ausdruecklich, statt sie zu verstecken, und der Workflow wird davon unabhaengig, wo er laeuft. So wurde `citation-anchors` korrigiert.
* **Das Werkzeug kommt ins Bild** - richtig fuer allgemeine Werkzeuge ohne Setup-Action (`shellcheck`, `python-is-python3`, `python3-yaml`). Die Zeile dafuer steht in Schicht 3 des `Containerfile`.

Node und Python liegen bewusst **nicht** im Bild: `setup-node` und `setup-uv` holen ihre eigenen Fassungen, und eine eingebackene Fassung wuerde mit ihnen streiten.

## Betrieb

Alle Befehle auf gex als `ghrunner`. Der Bequemlichkeit halber:

```sh
gxr() { cd /home/ghrunner && runuser -u ghrunner -- env HOME=/home/ghrunner \
  XDG_RUNTIME_DIR=/run/user/1001 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus "$@"; }
```

| Aufgabe | Befehl |
|---|---|
| Zustand | `gxr systemctl --user status 'gh-runner@*'` |
| Protokoll | `gxr journalctl --user-unit=gh-runner@lensclash-1.service -f` |
| laufende Container | `gxr podman ps` |
| Platz anhalten | `gxr systemctl --user stop gh-runner@lensclash-1.service` |
| Platz starten | `gxr systemctl --user start gh-runner@lensclash-1.service` |
| Bild neu bauen | `cd /home/ghrunner/image && gxr podman build --tag gh-runner:base .` danach jeden Platz neu starten |
| Deckel nachsehen | `gxr systemctl --user show gh-runner.slice -p CPUQuotaPerSecUSec -p MemoryMax` |

Ein Platz stoppt in Sekunden, wenn er untaetig ist, und laesst einen laufenden Auftrag zu Ende laufen (`TimeoutStopSec=300` ist die aeussere Grenze).

### Ein Repo anbinden

1. Repo in `/etc/gh-runner/repos` eintragen (**nur private Repos**).
2. Auf dem Laptop einmal `~/.local/bin/gh-runner-token-relay.sh` laufen lassen, damit sofort ein Token liegt.
3. `gxr systemctl --user enable --now gh-runner@<repo>-1.service` (und `-2` fuer einen zweiten Platz).
4. Im Repo `runs-on` umstellen - siehe [Uebergabe](gex-ci-uebergabe-phase2.md).

`testlab` steht als Rauchprobe-Repo in der Positivliste.
Sein Platz stand urspruenglich ab und war nur fuer eine Probe manuell zu starten; das liess echte PRs (aus der lensclash-Bahn) still und unsichtbar in der Warteschlange haengen, wenn `testlab` gerade gebraucht wurde.
Seit 22.08.2026 ist `testlab-1` deshalb dauerhaft aktiviert (`enabled`, `Restart=always`), wie jeder andere Platz - der Deckel traegt das muehelos, der Rauchprobe-Job ist leicht (s. [Plaetze](#plaetze)).

### Rueckbau

```sh
gxr systemctl --user disable --now 'gh-runner@*'          # Plaetze weg
gxr podman rmi localhost/gh-runner:base                    # Bild weg
loginctl disable-linger ghrunner && userdel -r ghrunner    # Nutzer weg
rm -rf /etc/gh-runner /opt/gh-runner                       # Konfiguration weg
apt-get purge podman uidmap slirp4netns fuse-overlayfs     # Pakete weg
```

Auf dem Laptop `systemctl --user disable --now gh-runner-token-relay.timer`.
Verwaiste Registrierungen bei GitHub abmelden: `gh api repos/swippipp/<repo>/actions/runners` und die IDs per `DELETE` entfernen.
Docker, Caddy, DNS und die Produktionscontainer sind zu keinem Zeitpunkt beteiligt.

## Grenzen und offene Punkte

* **Kalter Cache je Lauf.** Ephemeralitaet kostet den npm-/uv-Cache. Ein gemeinsam genutzter Cache-Datentraeger waere schneller, wuerde die Isolation zwischen Auftraegen aber aufweichen - bewusst nicht gebaut, erst messen.
* **Kein sudo im Container.** Das ist Absicht (Nicht-Root, `CapEff` leer), hat aber eine Folge: ein Workflow, der sich ein Systempaket per `sudo apt-get` nachinstalliert, faellt um. Betroffen sind genau zwei Repos, geprueft ueber alle zwoelf: `Bietkompass` (`poppler-utils`) und `SnackSuite` (`playwright install --with-deps`). Beide brauchen ihr Paket im Bild statt im Workflow.
* **Playwright fehlt.** Fuer SnackSuite braucht es eine zweite Bildvariante mit den Chromium-Systempaketen, bevor umgestellt wird.
* **Zwei Plaetze gegen drei gehostete.** lensclash faehrt drei Jobs parallel; der dritte wartet. Ein dritter Platz passt in den Deckel, wurde aber nicht in Betrieb genommen, weil der Gesamtlauf auch mit zweien schneller ist.
* **`nproc` luegt.** Siehe Abschnitt Deckel.
* **Das Relais haengt am Laptop.** Siehe Abschnitt Relais - bekannt, quantifiziert, und der Preis dafuer, dass auf gex kein Dauergeheimnis liegt.

## Maintaining this file

Diese Datei beschreibt den Betrieb genau einer Maschine.
Was der Code schon zeigt, gehoert nicht hierher - auf die Datei zeigen statt sie abzuschreiben.
Messwerte tragen ihr Datum; wer sie neu misst, ersetzt sie samt Datum, statt eine zweite Zahl danebenzustellen.
Die Umstellung einzelner Repos gehoert in die Uebergabe, nicht hierher.
