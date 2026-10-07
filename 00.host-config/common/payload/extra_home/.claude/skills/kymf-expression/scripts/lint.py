#!/usr/bin/env python3
"""
kymf-expression mechanical linter.

This handles the *lintable* half of the skill's self-lint: the checks that are
objective and boring to do by hand (semicolons, over-long sentences,
contractions, stray non-ASCII, and slop words). It deliberately does NOT judge
the things that need a human or model read - whether the emphatic word is last,
whether a sentence "makes good sense", whether a paragraph is hollow. Run this
first to clear the mechanical noise, then apply judgment to what remains.

It reads Markdown or plain text and reports findings by line. It is advisory:
some hits (a semicolon in standard mode, a word like "essential") are legitimate
in context, so they are marked "review" rather than "error".

Usage:
    python lint.py FILE [--mode strict|standard] [--max-words N] [--json]
    cat FILE | python lint.py - --mode standard

Exit code is 0 when nothing is flagged, 1 otherwise, so it can gate a build.
No third-party dependencies - standard library only.
"""

import argparse
import json
import re
import sys

# --- Slop blocklist (condensed from references/anti-ai-slop.md) --------------
# Single words are matched on word boundaries. Multi-word entries are matched
# as substrings. All matching is case-insensitive. These are prompts to look,
# not automatic failures - "essential" or "harness" can be the right word.
SLOP_WORDS = [
    "seamless", "robust", "powerful", "cutting-edge", "effortless",
    "world-class", "next-generation", "revolutionary", "game-changing",
    "best-in-class", "pivotal", "crucial", "vital", "essential", "testament",
    "delve", "leverage", "foster", "realm", "tapestry", "multifaceted",
    "elevate", "unlock", "harness", "underscore", "showcase", "surfacing",
]
SLOP_PHRASES = [
    "enduring legacy", "rich tapestry", "stands as", "plays a significant role",
    "it is important to note that", "it is worth mentioning",
    "ensuring reliability", "showcasing features", "highlighting capabilities",
    "enabling seamless integration", "fostering collaboration",
    "in today's fast-paced world", "in the ever-evolving landscape",
    "at the end of the day", "needless to say", "when it comes to",
    "spin up", "tear down", "kick off", "reach out",
]

# Explicit contraction list, so possessives like "Strunk's" are NOT flagged.
CONTRACTIONS = [
    "don't", "can't", "won't", "isn't", "aren't", "wasn't", "weren't",
    "doesn't", "didn't", "hasn't", "haven't", "hadn't", "shouldn't",
    "wouldn't", "couldn't", "it's", "that's", "there's", "we're", "they're",
    "you're", "i'm", "i've", "we've", "they've", "you've", "i'll", "we'll",
    "they'll", "you'll", "it'll", "i'd", "we'd", "they'd", "you'd", "let's",
]

INLINE_CODE = re.compile(r"`[^`]*`")
BRACKET_TOKEN = re.compile(r"\[[^\]]*\]")          # e.g. tag tokens like [->smb]
FENCE = re.compile(r"^\s*```")


def spans(pattern, text):
    """Return list of (start, end) character spans matched by pattern."""
    return [(m.start(), m.end()) for m in pattern.finditer(text)]


def in_any(idx, span_list):
    return any(s <= idx < e for s, e in span_list)


def strip_for_prose(line):
    """Blank out inline code so it is ignored, and drop emphasis markers."""
    line = INLINE_CODE.sub(lambda m: " " * (m.end() - m.start()), line)
    line = re.sub(r"\*\*|\*|_", "", line)
    return line


def is_table_row(line):
    return line.lstrip().startswith("|")


def split_sentences(text):
    return [s for s in re.split(r"(?<=[.!?])\s+", text) if s.strip()]


def lint(text, mode="standard", max_words=None):
    if max_words is None:
        max_words = 20 if mode == "strict" else 25
    findings = []           # (line_no, check, severity, message)
    in_fence = False

    for n, raw in enumerate(text.splitlines(), 1):
        if FENCE.match(raw):
            in_fence = not in_fence
            continue
        if in_fence:
            continue

        code_spans = spans(INLINE_CODE, raw)
        tag_spans = spans(BRACKET_TOKEN, raw)

        # Non-ASCII: allowed inside inline code (identifiers/paths) and inside
        # bracket tokens (e.g. the arrow in [->smb]-style tags).
        for i, ch in enumerate(raw):
            if ord(ch) > 127 and not in_any(i, code_spans) and not in_any(i, tag_spans):
                findings.append((n, "non-ascii", "error",
                                 f"non-ASCII {ch!r} (U+{ord(ch):04X})"))

        prose = strip_for_prose(raw)
        low = prose.lower()

        # Semicolons: banned in strict, review-only in standard.
        if ";" in prose and not is_table_row(raw):
            sev = "error" if mode == "strict" else "review"
            findings.append((n, "semicolon", sev, "semicolon in prose"))

        # Contractions.
        for c in CONTRACTIONS:
            if re.search(r"\b" + re.escape(c) + r"\b", low):
                findings.append((n, "contraction", "review", f'contraction "{c}"'))

        # Slop words and phrases.
        for w in SLOP_WORDS:
            if re.search(r"\b" + re.escape(w) + r"\b", low):
                findings.append((n, "slop", "review", f'slop word "{w}"'))
        for p in SLOP_PHRASES:
            if p in low:
                findings.append((n, "slop", "review", f'slop phrase "{p}"'))

        # Sentence length: skip tables, headings, and list-marker-only lines.
        if not is_table_row(raw) and not raw.lstrip().startswith("#"):
            body = re.sub(r"^\s*([-*>]|\d+\.)\s*", "", prose)
            for sent in split_sentences(body):
                wc = len(sent.split())
                if wc > max_words:
                    findings.append((n, "length", "review",
                                     f"sentence is {wc} words (cap {max_words})"))

    return findings


def main():
    ap = argparse.ArgumentParser(description="kymf-expression mechanical linter")
    ap.add_argument("file", help="path to a .md/.txt file, or - for stdin")
    ap.add_argument("--mode", choices=["strict", "standard"], default="standard")
    ap.add_argument("--max-words", type=int, default=None,
                    help="override the sentence-length cap")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args()

    text = sys.stdin.read() if args.file == "-" else open(args.file, encoding="utf-8").read()
    findings = lint(text, mode=args.mode, max_words=args.max_words)

    if args.json:
        print(json.dumps([
            {"line": ln, "check": ck, "severity": sv, "message": msg}
            for ln, ck, sv, msg in findings
        ], indent=2))
    else:
        errors = [f for f in findings if f[2] == "error"]
        reviews = [f for f in findings if f[2] == "review"]
        if not findings:
            print(f"CLEAN ({args.mode} mode): no mechanical issues found.")
        else:
            print(f"{len(errors)} error(s), {len(reviews)} to review ({args.mode} mode):\n")
            for ln, ck, sv, msg in findings:
                print(f"  line {ln:>4}  [{sv:<6}] {ck}: {msg}")
        # Group counts help spot patterns at a glance.
        counts = {}
        for _, ck, _, _ in findings:
            counts[ck] = counts.get(ck, 0) + 1
        if counts:
            print("\nby check: " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))

    # Errors fail the gate; review-only findings do not.
    return 1 if any(f[2] == "error" for f in findings) else 0


if __name__ == "__main__":
    sys.exit(main())
