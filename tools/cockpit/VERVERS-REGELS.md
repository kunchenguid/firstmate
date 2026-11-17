# Verversregels van de cockpit

Dit bestand beschrijft wat het script `tools/cockpit/refresh-cockpit.py` bij elke verversing doet.
Het script draait elk uur via firstmate, en direct als jij op "ververs" tikt.
De regels komen van jou (cockpit-rondes) en staan ook in je vaste regels bij firstmate (`data/captain.md`).

## Wat elke verversing bijwerkt
1. Kleur en status van elke kaart: uit de werkers (statusbestanden), de PR's (GitHub) en wat er live staat.
2. "Live bij klanten" betekent uitgerold: het script leest de stand van de onderdelen in de versie die echt op miko-os.ai draait (de laatste geslaagde productie-uitrol), niet alleen main.
3. Elke actieve werker staat op het bord. Ontbreekt er een, dan komt er vanzelf een kaart én een WBS-blokje bij.
4. Kaart en WBS-blokje staan op dezelfde stap, en dus in dezelfde kolom.
5. De G1-G10-strook op elke kaart, uit het bewijsbestand op main (prod-gate.json).
6. Afhankelijkheden: "kan starten" per blokje, opnieuw berekend uit de pijlen.
7. WBS-blokjes en pop-ups zeggen hetzelfde als hun kaart, met de laatste melding van de werker.
8. Kolom 8: kaarten die langer dan 2 dagen klaar zijn, staan dichtgeklapt.
9. Tijden bovenaan blok 1 en bij de Kanban.

## Wat elke verversing controleert
10. Statussen: gekleurd terwijl de tekst zegt dat het nu niet loopt.
11. Kolommen: kaart en WBS-blokje op een andere stap.
12. Afhankelijkheden: iets loopt terwijl iets ervoor nog open staat.
13. Tekst: een PR die "wacht" maar al op main staat, of een vraag bovenaan die niet meer openstaat.
14. De architectuurtekening: ouder dan de bron op main?

De uitkomst staat achter de kop van de Kanban: "bordcontrole: alles klopt", of in oranje het aantal afwijkingen.

## Vaste werkregels
- Een status uit een bericht neem ik pas over als ik hem heb nagekeken: in GitHub, bij de werker of in de uitrol.
- Twee keer achter elkaar verversen moet nul verschillen geven.
- Tot jij zegt dat we live gaan voor klanten, houden we niets tegen voor beveiliging: reparaties lopen ernaast.

Let op: dit bestand en de scripts staan onder versiebeheer in `tools/cockpit/` van de firstmate-repo.
De paden komen uit omgevingsvariabelen; zie `tools/cockpit/README.md`.
