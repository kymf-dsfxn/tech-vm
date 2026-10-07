# STE Essentials (self-contained)

These are the ASD-STE100 rules that this skill needs, condensed from the full standard so this skill works on its own. For the complete rules, dictionary, checklist, and background, use the standalone ASD-STE100 skill or the free standard at asd-ste100.org.

STE has 53 writing rules in 9 sections plus a controlled dictionary of ~900 approved words. This file covers the rules that matter most for everyday writing.

## Text Types

Every rule depends on whether the text is procedural or descriptive. Classify first.

| | Procedures (instructions) - Section 5 | Descriptions (explanations) - Section 6 |
| --- | --- | --- |
| Purpose | Tell the reader what to do | Explain how things work, or what happened |
| Voice | Active, imperative form ("Install the pump") | Active preferred, passive only when the agent is unknown |
| Sentence limit (strict mode) | 20 words maximum (Rule 5.1) | 25 words maximum (Rule 6.3) |
| Structure | One instruction per sentence (Rule 5.2) | One topic per paragraph, max 6 sentences (Rules 6.5, 6.6) |

Do not mix the two types in one passage. If source text mixes them, separate the instructions from the explanations first.

## Words

- Use one name for one thing. Do not call the same item by two names.
- Use the short, common word: start (not begin/commence/initiate), use (not utilize/leverage), help (not facilitate), make sure (not ensure), before (not prior to), after (not subsequent to), about (not regarding), get (not obtain), show (not demonstrate), also (not additionally/furthermore/moreover).
- Give each word one meaning. "fall" means to move down, not to decrease.
- American spelling (colour -> color, centre -> center).
- Technical nouns and verbs from official documentation are allowed even when they are not "common" words (for example "hydraulic pump assembly", "to ream").

## Verbs (Rule 3)

Approved verb forms: infinitive, imperative, simple present, simple past, simple future, and past participle as an adjective only ("the installed component").

Not allowed:

- Modal verbs: can, could, may, might, should, would (lowercase). UPPERCASE RFC 2119 key words in requirement text are exempt (see Conformance below).
- Progressive tenses and complex auxiliary constructions ("must be installing" -> "install").
- "-ing" forms as verbs. They are allowed only as technical nouns ("the opening") or as modifiers inside a technical noun.
- Passive voice in procedures.
- Nominalizations. Use a verb for an action ("analyze the log", not "perform an analysis of the log").

## Sentences (Rule 4)

- Write short, clear sentences.
- Do not omit words or use contractions to shorten a sentence. Keep the subject, the verb, and the articles (a, an, the).
- Use a vertical list for a complex sequence, one action per item.
- Put the condition first: "If X, do Y", not "Do Y if X".

## Multi-word Nouns (Rule 2)

- Maximum three words in a multi-word noun (Rule 2.1).
- For longer clusters, use a prepositional phrase or hyphens. Bad: "main landing gear shock absorber assembly". Better: "shock absorber assembly of the main landing gear".
- A hyphenated group counts as one word (Rule 8.7).

## Punctuation (Rule 8)

- You may use all standard English punctuation except the semicolon (Rule 8.1). In strict mode, write two sentences instead.
- Dashes are not banned. Only the semicolon is.
- Use hyphens to connect directly related words (Rule 8.2).

## Safety Instructions (Section 7)

- Start with a clear command or condition.
- Use the defined levels: WARNING, CAUTION, NOTE.
- Legal teams may control warning text. Flag a rewrite of warning text rather than change it silently.

## Conformance (RFC 2119)

Requirement text MUST conform to RFC 2119. When you state a requirement, use the RFC 2119 key words and include this phrase near the start of the text:

> The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119.

Write these key words in UPPERCASE. In UPPERCASE, they are requirement-level terms, not ordinary modal verbs, and the ban on lowercase modals does not apply to them.

## Example Transformations

| Non-STE | STE |
| --- | --- |
| "Before acceptance of unit..." | "Before you accept the unit, do the specified test procedure." |
| "Rotate the cover until the jacks are accessible." | "Turn the cover until you can get access to the jacks." |
| "The unit must be installed carefully." | "Install the unit carefully." |
| "Examine the removed parts; replace the damaged ones." | "Examine the removed parts. Then replace the damaged ones." |
