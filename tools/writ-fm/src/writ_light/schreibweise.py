"""Schreibweisen-Aufraeumen: ae/oe/ue -> echte Umlaute in den Anzeigetexten.

Der Bestand ist uneinheitlich gewachsen. Fuer die Suche ist das seit der
Normalisierung in `schema.normalisieren` egal — fuer den Lesenden nicht.

**Warum eine kuratierte Wortliste und keine Zeichenregel.** Eine blinde
Ersetzung von ae/oe/ue zerlegt deutsche Woerter, in denen die Buchstabenfolge
kein ersetzter Umlaut ist. Gemessen am Bestand: 38 der 225 betroffenen Woerter
sind solche falschen Freunde ("bauen" -> "baün", "Quelle" -> "Qülle",
"Sequenz" -> "Seqünz"). Dazu kommen Woerter, in denen nur EIN Vorkommen
gemeint ist ("primaerquelle" -> "primärquelle", nicht "primärqülle") und
solche, die zusaetzlich ein scharfes S brauchen ("groesserer" -> "größerer").

Deshalb: explizite Zuordnung. Was nicht in ERSETZUNGEN steht, bleibt stehen —
"im Zweifel nicht ersetzen".
"""

from __future__ import annotations

import re

# Nicht ersetzen: die Buchstabenfolge ist hier kein ersetzter Umlaut.
# Nur zur Dokumentation und fuer den Bericht — die Wirkung ergibt sich
# daraus, dass diese Woerter in ERSETZUNGEN fehlen.
AUSNAHMEN = {
    # deutsches au/eu/qu, kein Umlaut
    "aktuell", "aktuellen", "aufbauen", "bauen", "bequemer", "dauer",
    "dauerbrenner", "dauerhaft", "dauerhaftes", "dauerzustand", "einbauen", "einstreuen",
    "fernsteuerungs",
    "fremdquellen", "konsequenz", "manuell", "manuelles", "neue", "neuen",
    "neuentwicklung", "neues", "quelle", "sequentiell", "sequenz", "steuerung",
    "teuerste", "vertrauen", "zuerst",
    "aktuelle", "aktueller", "fremdquelle", "quellen", "quelldokument",
    "quelldokumente", "quellendeckung", "teuer",
    # englische Begriffe und Bezeichner
    "approvalqueue", "fuel", "issues", "known_issues", "query", "queue",
    "queues", "request", "requests", "true", "unique",
    # Eigennamen
    "maestro",
}

ERSETZUNGEN = {
    "abhaengigkeit": "abhängigkeit", "abhaengigkeiten": "abhängigkeiten",
    "absaetze": "absätze", "abwuergen": "abwürgen", "aelterer": "älterer",
    "aendern": "ändern", "aendert": "ändert", "aenderung": "änderung",
    "aenderungen": "änderungen", "anfuehrungszeichen": "anführungszeichen",
    "angekuendigt": "angekündigt", "angekuendigte": "angekündigte",
    "ankuendigung": "ankündigung", "auffaelligkeit": "auffälligkeit",
    "aufloesung": "auflösung", "aufraeumen": "aufräumen",
    "aufzufuellen": "aufzufüllen", "ausdruecklich": "ausdrücklich",
    "ausdruecklichen": "ausdrücklichen", "ausdruecklicher": "ausdrücklicher",
    "ausfuehren": "ausführen", "ausfuehrende": "ausführende",
    "ausfuehrenden": "ausführenden", "ausgeloest": "ausgelöst",
    "ausgeschmueckt": "ausgeschmückt", "ausgewaehlt": "ausgewählt",
    "ausloesen": "auslösen", "auswahlmoeglichkeiten": "auswahlmöglichkeiten",
    "begruendung": "begründung", "beruehrt": "berührt",
    "beschluesse": "beschlüsse", "bestaetigen": "bestätigen",
    "bestaetigendes": "bestätigendes", "bestaetigt": "bestätigt",
    "bestaetigung": "bestätigung", "bezuege": "bezüge", "buehne": "bühne",
    "buerger": "bürger", "duerfen": "dürfen", "eigenmaechtige": "eigenmächtige",
    "eignungspruefung": "eignungsprüfung", "einfuehren": "einführen",
    "eingestaendnis": "eingeständnis", "einhaengen": "einhängen",
    "einschaetzung": "einschätzung", "einverstaendnis": "einverständnis",
    "entfaellt": "entfällt", "entwuerfe": "entwürfe", "ergaenzen": "ergänzen",
    "erklaerender": "erklärender", "erwaehnen": "erwähnen", "faehrt": "fährt",
    "faelle": "fälle", "faellt": "fällt", "faengt": "fängt",
    "foerderquote": "förderquote", "fruehem": "frühem", "fuehrt": "führt",
    "fuellen": "füllen", "fuenf": "fünf", "fuer": "für",
    "geaendert": "geändert", "gedaechtnis": "gedächtnis",
    "gefaellig": "gefällig", "gegenpruefen": "gegenprüfen",
    "gehoeren": "gehören", "gehoert": "gehört", "geprueft": "geprüft",
    "geraet": "gerät", "geraete": "geräte", "geraetetest": "gerätetest",
    "geruest": "gerüst",
    # scharfes S: "groesser" wird "größer", nicht "grösser"
    "groessenordnungen": "größenordnungen", "groesserer": "größerer",
    "mittelmaessig": "mittelmäßig",
    "gruen": "grün", "gruende": "gründe", "gruene": "grüne",
    "gruenen": "grünen", "gueltigem": "gültigem", "haelfte": "hälfte",
    "haelt": "hält", "haengengeblieben": "hängengeblieben",
    "hinzugefuegt": "hinzugefügt", "hoechstens": "höchstens",
    "hoeren": "hören", "identitaet": "identität", "kaempfe": "kämpfe",
    "kapazitaet": "kapazität",
    "kategorieuebergreifende": "kategorieübergreifende", "klaeren": "klären",
    "koennte": "könnte", "kuenstlich": "künstlich", "laesst": "lässt",
    "laeufe": "läufe", "laeuft": "läuft", "loescht": "löscht",
    "loesen": "lösen", "loest": "löst", "loesung": "lösung",
    "luecke": "lücke", "luegt": "lügt", "mitzaehlen": "mitzählen",
    "moeglich": "möglich", "monatsvertraege": "monatsverträge",
    "muessen": "müssen", "nachschaerfen": "nachschärfen",
    "naechste": "nächste", "naechsten": "nächsten", "naeher": "näher",
    "naehert": "nähert", "noetig": "nötig", "oberflaeche": "oberfläche",
    "oeffnen": "öffnen", "passwoerter": "passwörter",
    "plausibilitaets": "plausibilitäts", "ploetzlich": "plötzlich",
    "praefix": "präfix",
    # nur das erste Vorkommen ist ein Umlaut — "quelle" bleibt "quelle"
    "primaerquelle": "primärquelle",
    "produktionsrealitaet": "produktionsrealität", "pruefbare": "prüfbare",
    "pruefen": "prüfen", "pruefer": "prüfer", "prueft": "prüft",
    "pruefung": "prüfung", "punktezaehler": "punktezähler",
    "qualitaet": "qualität", "qualitaetsurteile": "qualitätsurteile",
    "randfaelle": "randfälle", "realitaets": "realitäts",
    "regelaenderung": "regeländerung", "rueckfrage": "rückfrage",
    "rueckfragen": "rückfragen", "rueckmeldung": "rückmeldung",
    "rueckt": "rückt", "rueckwaerts": "rückwärts", "saetze": "sätze",
    "schaetzen": "schätzen", "schaltflaechen": "schaltflächen",
    "schlaegt": "schlägt", "schluessel": "schlüssel",
    "schraegstriche": "schrägstriche", "schueler": "schüler",
    "schuelerdaten": "schülerdaten", "schuelertext": "schülertext",
    "spaeter": "später", "staerker": "stärker", "testfaelle": "testfälle",
    "testgeraet": "testgerät", "traegt": "trägt", "ueber": "über",
    "ueberall": "überall", "ueberblick": "überblick",
    "uebergaenge": "übergänge", "uebergangsregel": "übergangsregel",
    "ueberhaupt": "überhaupt", "ueberlassen": "überlassen",
    "ueberleben": "überleben", "ueberliest": "überliest",
    "uebernehmen": "übernehmen", "uebernimmt": "übernimmt",
    "uebernommen": "übernommen", "uebertraegt": "überträgt",
    "uebertragen": "übertragen", "ueberwachungslauf": "überwachungslauf",
    "umstaende": "umstände", "unmoeglich": "unmöglich",
    "unmoegliche": "unmögliche", "urteilsvermoegen": "urteilsvermögen",
    "verfuegbar": "verfügbar", "verlaengerung": "verlängerung",
    "verstaendlich": "verständlich", "verwaessern": "verwässern",
    "vollstaendiger": "vollständiger", "waechter": "wächter",
    "waehlen": "wählen", "waehlt": "wählt", "waehrend": "während",
    "woertlich": "wörtlich", "wuerde": "würde", "zaehlen": "zählen",
    "zaehlt": "zählt", "zurueck": "zurück", "zurueckgeben": "zurückgeben",
    "zurueckmelden": "zurückmelden", "zusaetzlich": "zusätzlich",
    "zustandstraeger": "zustandsträger",
    # Woerter, die nur in den Dateikopf-Kommentaren vorkommen
    "aufgeloest": "aufgelöst", "aufzaehlung": "aufzählung",
    "ausfuehrt": "ausführt", "enthaelt": "enthält", "groessen": "größen",
    "haengt": "hängt", "hoechste": "höchste", "klaert": "klärt",
    "kuenftige": "künftige", "loeschen": "löschen", "prioritaet": "priorität",
    "rueckbau": "rückbau", "standardmaessig": "standardmäßig",
    "taeglich": "täglich", "uebergangscharakter": "übergangscharakter",
    "vollstaendig": "vollständig", "zaehler": "zähler",
    # Scharfes S. Diese Woerter enthalten kein ae/oe/ue und standen deshalb
    # nicht auf der urspruenglichen Liste — sie fielen erst beim Durchsehen
    # des Diffs auf, direkt neben dem frisch korrigierten "größer".
    # Nicht angetastet werden die 87 Woerter mit korrektem ss (Session,
    # Prozess, Klasse, muss, dass, lassen, wissen, messen, Adresse …).
    "abschliessende": "abschließende", "ausschliesslich": "ausschließlich",
    "aussen": "außen", "aussenwirkung": "außenwirkung", "draussen": "draußen",
    "frassen": "fraßen", "gross": "groß", "heissen": "heißen",
    "heisst": "heißt", "massgeblich": "maßgeblich",
    "schliessen": "schließen", "verbrauchsmass": "verbrauchsmaß",
    "verstoss": "verstoß",
}

# Ergebnisse der Ersetzung duerfen nicht erneut als offen gemeldet werden:
# "primärquelle" enthaelt weiterhin die Folge "ue" (in "quelle").
_FERTIG = frozenset(ERSETZUNGEN.values())

_WORT = re.compile(r"[A-Za-zÄÖÜäöüß_]+")
# Alles in Backticks ist Code, Pfad oder Bezeichner und bleibt unberuehrt.
_CODE = re.compile(r"`[^`]*`")


def _ersetze_wort(m: re.Match) -> str:
    wort = m.group(0)
    neu = ERSETZUNGEN.get(wort.lower())
    if neu is None:
        return wort
    if wort.isupper():
        return wort  # ENV-Namen und Versalien bleiben, wie sie sind
    return neu[0].upper() + neu[1:] if wort[0].isupper() else neu


def umschreiben(text: str) -> str:
    """Anzeigetext aufraeumen. Code in Backticks bleibt unangetastet."""
    teile, letzte = [], 0
    for code in _CODE.finditer(text):
        teile.append(_WORT.sub(_ersetze_wort, text[letzte:code.start()]))
        teile.append(code.group(0))
        letzte = code.end()
    teile.append(_WORT.sub(_ersetze_wort, text[letzte:]))
    return "".join(teile)


def offene_kandidaten(text: str) -> set[str]:
    """Woerter mit ae/oe/ue, die weder ersetzt noch als Ausnahme gefuehrt sind.

    Fuer den Bericht: was beim naechsten Durchgang zu entscheiden waere.
    """
    ohne_code = _CODE.sub(" ", text)
    raus = set()
    for m in _WORT.finditer(ohne_code):
        roh = m.group(0)
        if roh.isupper():
            continue  # Regel-IDs und ENV-Namen werden ohnehin nie ersetzt
        w = roh.lower()
        if len(w) > 3 and re.search(r"ae|oe|ue", w) \
                and w not in ERSETZUNGEN and w not in AUSNAHMEN and w not in _FERTIG:
            raus.add(w)
    return raus
