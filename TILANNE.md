# FIRSTMATE - sessiolukon P0-korjauksen tilanne

Päivä: 2026-07-23.

Haara: `fm/lukko-korjaus-p0`.

Tila: osittainen ja turvallisesti commitoitu kapteenin 8.7. pyynnöstä.

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
- `AGENTS.md` kuvaa uuden lukitussopimuksen.
- `docs/configuration.md` kutsuu detect-only-tilaa ei-omistavaksi session-start-tilaksi.
- Uusi `tests/fm-lock.test.sh` kattaa pyydetyt lukitusregressiot sekä reclaimin sisäisen uudelleenvertailun, vahvistetun Codex-haltuunoton ja ehdottoman clear-komennon kiellon.
- `tests/fm-session-start.test.sh` kattaa vain `LIVE_OTHER`-tuloksesta syntyvän read-only-tilan ja saman session stale-reclaim-jatkon.
- Uusi lukitustesti on liitetty `session-bootstrap`-testiperheeseen.
- `data/learnings.md`:ään ei ole koskettu, koska korjaus ei ole päähaarassa.

## Todennettu

- `tests/fm-lock.test.sh`: kaikki 10 testiä läpi.
- `tests/fm-session-start.test.sh`: kaikki testit läpi.
- `tests/fm-grok-harness.test.sh`: läpi.
- `tests/fm-supervision-instructions.test.sh`: läpi.
- `tests/fm-test-run.test.sh`: läpi.
- `bin/fm-test-run.sh --check-coverage`: läpi, 95 testiä katettu.
- `bin/fm-lint.sh`: läpi ShellCheck 0.11.0:lla.
- `shellcheck -x` muutetuille skripteille: läpi.
- `git diff --check`: läpi ennen tätä tilannekirjausta.

## Kesken

- `tests/fm-instruction-owners.test.sh` odottaa vielä vanhaa lausetta `A lock-refused session must not ...`.
- Tuo sopimustesti pitää päivittää vaatimaan uusi turvallisuusperiaate: vain `LIVE_OTHER` on read-only, mutta mikään ei-omistettu tila ei saa mutatoida fleet-tilaa.
- Koko `bin/fm-test-run.sh --all` -ajo keskeytettiin kapteenin 8.7. pyynnöstä.
- Keskeytetyssä koko ajossa havaittiin ennen keskeytystä kolme punaista tulosta:
  - `tests/fm-backend-orca.test.sh` osui tunnettuun macOS Bash 3.2 -vikaan, joka vastaa avointa issuea #886.
  - `tests/fm-calm-pi-extension.test.sh` vaatii Pi-version 0.81.1, mutta koneella on 0.80.10.
  - `tests/fm-instruction-owners.test.sh` osui yllä kuvattuun tehtävään kuuluvaan vanhan lauseen odotukseen.
- Keskeytys katkaisi `tests/fm-wake-queue.test.sh`-ajon signaalilla ja lopetti koko runnerin exit-koodiin 130.
- No-mistakes-validointia ei ole aloitettu.
- Haaraa ei ole pushattu eikä PR:ää ole avattu.

## Seuraava askel

Päivitä vain `tests/fm-instruction-owners.test.sh`:n vanhentunut lukkolauseen odotus uuden tyypitetyn sopimuksen mukaiseksi.

Aja sen jälkeen kohdistetut lukko- ja sopimustestit, `bin/fm-lint.sh` ja koko testisarja uudelleen.

Kun paikallinen validointi on valmis, tee uusi commit ja käynnistä no-mistakes tämän tehtävän alkuperäisellä intentillä.
