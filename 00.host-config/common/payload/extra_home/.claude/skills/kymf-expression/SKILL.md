---
name: kymf-expression
description: Kym Farrell's writing style. Use when writing or editing prose that will be associated with Kym. Documents, designs, reports, READMEs, emails, PR text, release notes, error messages, comments, and explanations. It joins ASD-STE100 Simplified Technical English (clear, mechanical, translatable form) with William Strunk's Elements of Style (force and craft) and an anti-AI-slop filter. Two modes - strict (procedures/safety, full STE) and standard (general prose, the default). Trigger phrases include "write with kymf-expression", "make this concise/clear", "edit this for clarity", or any request to produce prose Kym will use.
metadata:
  version: 1.0.0
---

# kymf-expression - Kym Farrell's Writing Style

Write prose that is clear, direct, and free of "AI slop". This skill is self-contained. It combines three sources into one standard:

- **ASD-STE100 Simplified Technical English (STE)** - the mechanical, lintable form: short sentences, active voice, plain verbs, no semicolons, consistent terms. See `references/ste-essentials.md`.
- **Strunk, *The Elements of Style*** - the craft: positive form, concrete language, cut needless words, emphatic word last. See `references/strunk-clarity.md`.
- **Anti-AI-slop filter** - cut puffery, elegant variation, the rule of three, and the other patterns that make text read like a machine. See `references/anti-ai-slop.md`.

This applies to prose, not code, identifiers, or command syntax. It is not for writing that needs a distinct persona or marketing voice.

## Kym's Defaults (house style)

Apply these in every mode unless Kym asks otherwise:

- Be concise and direct. Cut every word that does not change the meaning. A test: if you can remove a word and keep the point, remove it.
- Prefer prose to lists. Use bullets, headers, and tables only when they make the content clearer, not by default.
- Use bold rarely. Let the sentence carry the emphasis.
- Use ASCII characters
- State things in the positive. Say what is, not what is not.
- Use concrete, specific words. "The build failed" beats "an issue occurred".
- Put the most important word or idea at the end of the sentence.
- Do not pad. No preamble, no throat-clearing, no summary of what you are about to say.

## Two Modes - Choose One First

| Mode                   | Use for                                                                                                     | What to apply                                                                                                                                              |
| ---------------------- | ----------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **strict**             | Procedures, runbooks, safety text (WARNING/CAUTION/NOTE), formal STE documentation (S1000D, ATA iSpec 2200) | Full STE: hard word-count caps, approved verb forms, no semicolons, no passive in procedures. Strunk and the slop filter fill the gaps STE does not cover. |
| **standard** (default) | Everything else Kym writes - documents, reports, emails, READMEs, PR text, release notes, comments          | STE's discipline for form, but Strunk's craft wins where the two clash (see precedence). Keep the slop filter and one-name-per-thing rule.                 |

Default to standard. Use strict only for procedures, safety text, or when Kym asks for full STE.

## Precedence - When STE and Strunk Conflict

STE and Strunk agree on most points: active voice, concision, concrete language, one topic per paragraph, related words together. Where they conflict, resolve by mode.

| Conflict        | strict mode                                                                    | standard mode (default)                                                                                                                  |
| --------------- | ------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Sentence length | Hard caps: 20 words (procedures), 25 words (descriptions)                      | No hard cap. Keep most sentences short, but vary length for rhythm. Avoid a run of similar loose sentences (Strunk Rule 14).             |
| Semicolons      | Banned (STE Rule 8.1) - write two sentences                                    | Prefer two sentences. A semicolon is allowed when it joins two closely related independent clauses and a period would break the thought. |
| Passive voice   | Banned in procedures                                                           | Active by default. Passive is allowed when the object is the true subject of the sentence (Strunk Rule 10).                              |
| Vocabulary      | ~900 approved STE words plus technical terms                                   | Full language. Still prefer the short, common word, and use one name for one thing.                                                      |
| Modal verbs     | Banned lowercase. UPPERCASE RFC 2119 key words in requirement text are exempt. | Allowed, but sparingly. Prefer a direct statement to "may" or "should".                                                                  |
| Voice           | Stripped for translation                                                       | Keep a clear, plain voice. Cut puffery, not personality.                                                                                 |

The rule of thumb: strict mode protects translation and safety, so form wins. standard mode protects readability, so craft wins - but the mechanical anti-slop checks always apply.

## Workflow

1. Pick the mode. Procedures, safety text and code-comments use strict. Everything else uses standard.
2. Draft the content. Say the true thing first, then fix the form.
3. Apply STE form: active voice, plain verbs, short sentences, no semicolons in strict mode. See `references/ste-essentials.md`.
4. Apply Strunk's craft: positive form, concrete words, cut needless words, emphatic word last. See `references/strunk-clarity.md`.
5. Run the anti-slop filter. See `references/anti-ai-slop.md`.
6. Apply Kym's defaults: concise, direct, minimal formatting, ASCII.
7. Run the self-lint below.

## Self-Lint (run before returning any text)

The self-lint has two halves. The mechanical half is boring and objective, so hand it to the bundled linter. The judgment half needs a read, so do it yourself.

**Mechanical pass - run the script.** For a file, run:

```
python scripts/lint.py <file> --mode standard   # or --mode strict
```

It flags semicolons, over-long sentences (cap 20 strict / 25 standard), contractions, stray non-ASCII (tag tokens and code are exempt), and slop words. It marks each finding `error` (fix it) or `review` (judge in context - a semicolon that joins two clauses, or a long quoted requirement phrase, can be fine). Exit code is 0 when clean, so it can gate a build. If you cannot run the script (no file, or no Python), fall through to the manual checks below, which cover the same ground:

1. Any sentence over 20 words (strict, procedure) or 25 (strict, description)? Split it. In standard mode, flag only sentences that are hard to follow.
2. Any semicolon in strict mode? Replace with a period. In standard mode, keep it only if it joins two related clauses.
3. Any contraction where the text is formal? Any omitted subject, verb, or article? Restore it.
4. Any passive voice with a known actor? Make it active (unless the object is the true subject).
5. Any modal (can, may, should, would), "-ing" main verb, nominalization ("perform an analysis"), or phrasal verb ("spin up")? Replace with a plain verb.

**Judgment pass - do this yourself** (the script cannot, and should not, guess at these).

Craft (Strunk):

6. Any negative that hides a positive ("did not remember" --> "forgot")? Rewrite in the positive.
7. Any vague or abstract word where a concrete one fits ("an issue occurred" --> "the disk filled")? Replace it.
8. Any needless words ("the fact that", "in order to", "there is ... which")? Cut them.
9. Is the most important idea at the end of the sentence? If not, move it.

Slop and house style:

10. Any puffery, marketing adjective, or overused AI word (delve, leverage, seamless, robust, foster, surfacing, tapestry)? Cut it.
11. Any rule-of-three padding, elegant variation, or empty "-ing" phrase ("ensuring reliability")? Cut it.
12. Same thing named two ways? Pick one name.
13. Over-formatted? Convert needless bullets to prose. Remove decorative bold.

## Attribution and Constraints

- STE rules are paraphrased from ASD-STE100. ASD-STE100 is a registered EU trademark (No. 017966390). The controlled dictionary is copyrighted and is not reproduced here. The free standard is at asd-ste100.org.
- Strunk's *The Elements of Style* (1918) is in the public domain.
- The anti-slop patterns are condensed from Wikipedia's guide to detecting AI-generated writing (CC BY-SA).
- No tool can guarantee STE compliance. For formal STE deliverables, a human writer signs off on the final text.
- This skill fixes the form and cuts slop. It cannot make a hollow paragraph true.
