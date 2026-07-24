# FIRSTMATE - sessiolukon P0-korjauksen tilanne

Päivä: 2026-07-24.

Haara: `fm/lukko-korjaus-p0`.

Tila: koodityö valmis ja committoitu; validointi ja PR odottavat kapteenin aamupäätöstä.

## Valmista

- `bin/fm-lock.sh` erottaa tulokset `OWNED`, `LIVE_OTHER`, `STALE_RECLAIMABLE` ja `IDENTITY_UNAVAILABLE`.
- Numeerinen omistaja on vanhentunut vain, kun `kill -0` epäonnistuu tai luettava prosessi-identiteetti todistaa prosessin muuksi kuin harnessiksi.
- Elävä numeerinen omistaja säilyy koskemattomana, jos `ps` ei ole luettavissa.
- Codex käyttää normaalia prosessipuuta ensisijaisesti ja `CODEX_THREAD_ID`:tä vain, kun prosessipuuta ei voi tarkastaa.
- Sama `codex-thread:<id>` tunnistetaan omaksi ilman `ps`:ää.
- Vierasta Codex-säiettä ei luokitella automaattisesti vanhentuneeksi.
- `reclaim --expected <owner>` vertaa omistajan ennen lyhyttä reclaim-lukkoa ja uudelleen lukon sisällä.
- Reclaim tarkistaa saman vanhentumistodisteen uudelleen ennen atomista omistajan vaihtoa.
- `--confirmed-closed` mahdollistaa vieraan Codex-säikeen kohdistetun haltuunoton vain odotetun omistajan vertailulla.
- Yleinen ehdoton `clear` on poistettu käytöstä.
- `bin/fm-session-start.sh` asettaa read-only-tilan vain `LIVE_OTHER`-tuloksesta.
- `IDENTITY_UNAVAILABLE` estää mutaatiot mutta ei väitä toista elävää sessiota.
- Vanhentunut numeerinen lukko ja estetty `ps` vallataan Codex-tunnisteella, minkä jälkeen sama session-start jatkaa herätysjonon tyhjennykseen.
- Valvontaohjeen lukitila tukee uusia tyypitettyjä tuloksia.
- Löydös `non-owned-mutation-instructions` on toteutettu päätöstiedoston `data/lukko-korjaus-p0/paatos-non-owned-mutation.md` mukaisesti: `bin/fm-supervision-instructions.sh` pidättää harness-protokollan ja kaikki muut fleet-mutaatio-ohjeet jokaisessa ei-omistetussa lukkotilassa.
- Pidätys ei katkaise palautuspolkua: `STALE_RECLAIMABLE` tarjoaa atomisen reclaim-polun ainoana sallittuna mutaationa, ja `bin/fm-session-start.sh`:n sulkumuistutus osoittaa siihen.
- `IDENTITY_UNAVAILABLE`-ohje ei väitä elävää kilpailijaa eikä tarjoa ehdotonta reclaimia; vain kapteenin vahvistama `--confirmed-closed`-polku mainitaan.
- `tests/fm-instruction-owners.test.sh` vaatii uuden tyypitetyn sopimuksen lauseet.
- `AGENTS.md` kuvaa uuden lukitussopimuksen.
- `docs/configuration.md` kutsuu detect-only-tilaa ei-omistavaksi session-start-tilaksi.
- Uusi `tests/fm-lock.test.sh` kattaa pyydetyt lukitusregressiot sekä reclaimin sisäisen uudelleenvertailun, vahvistetun Codex-haltuunoton ja ehdottoman clear-komennon kiellon.
- `tests/fm-session-start.test.sh` kattaa vain `LIVE_OTHER`-tuloksesta syntyvän read-only-tilan, saman session stale-reclaim-jatkon normaalilla valvontablokilla sekä ohjeiden pidätyksen `LIVE_OTHER`- ja `IDENTITY_UNAVAILABLE`-poluilla.
- `tests/fm-supervision-instructions.test.sh` kattaa pidätyksen kaikissa kolmessa ei-omistetussa tilassa, reclaim-tarjouksen vain `STALE_RECLAIMABLE`-tilassa ja muuttumattoman `OWNED`-protokollan.
- Uusi lukitustesti on liitetty `session-bootstrap`-testiperheeseen.
- `data/learnings.md`:ään ei ole koskettu, koska korjaus ei ole päähaarassa.

## Todennettu 2026-07-24

- `tests/fm-lock.test.sh`: kaikki 10 testiä läpi.
- `tests/fm-session-start.test.sh`: kaikki testit läpi.
- `tests/fm-supervision-instructions.test.sh`: kaikki testit läpi, mukaan lukien uusi pidätystesti.
- `tests/fm-instruction-owners.test.sh`: läpi.
- `tests/fm-turnend-guard.test.sh` ja `tests/fm-guard-stale-banner.test.sh`: läpi.
- `bin/fm-test-run.sh --family session-bootstrap`: 9/9 skriptiä läpi.
- `bin/fm-test-run.sh --check-coverage`: läpi, 95 testiä katettu.
- `bin/fm-lint.sh`: läpi ShellCheck 0.11.0:lla.

## Tunnetut ympäristöpunaiset, eivät tämän tehtävän vikoja

- `tests/fm-backend-orca.test.sh` osuu tunnettuun macOS Bash 3.2 -vikaan, joka vastaa avointa issuea #886.
- `tests/fm-calm-pi-extension.test.sh` vaatii Pi-version 0.81.1, mutta koneella on 0.80.10.

## Kesken

- No-mistakes-validointia ei voi ajaa nyt: Codexin krediitit ovat lopussa ja varapolku kaatuu tunnettuun `ANTHROPIC_API_KEY`-estoon.
- Haaraa ei ole pushattu eikä PR:ää ole avattu.

## Seuraava askel

Kapteeni päättää aamulla, miten validointi ja PR hoidetaan.

Kun korjaus on päähaarassa, päivitä `data/learnings.md`.
