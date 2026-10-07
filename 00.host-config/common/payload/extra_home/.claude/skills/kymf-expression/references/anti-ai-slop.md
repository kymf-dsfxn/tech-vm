# Anti-AI-Slop Filter

"Slop" is prose that reads like generic machine output: puffed up, hedged, padded, and over-formatted. This filter merges the ASD-STE100 word blocklist with the highest-value patterns from Wikipedia's guide to detecting AI-generated writing. Cut these in every mode.

The full Wikipedia guide covers many patterns specific to encyclopedia editing (draft templates, citation markup, category pages). Those are omitted here. This file keeps the patterns that appear in the prose Kym writes.

## Word and Phrase Blocklist

**Marketing adjectives:** seamless, robust, powerful, cutting-edge, effortless, world-class, next-generation, revolutionary, game-changing, best-in-class.

**Puffery and importance-inflation:** pivotal, crucial, vital, essential, testament, enduring legacy, rich tapestry, stands as, plays a significant role, it is important to note that, it is worth mentioning.

**Overused AI vocabulary:** delve, leverage, foster, realm, tapestry, multifaceted, elevate, unlock, harness, navigate (figurative), underscore, showcase.

**Empty "-ing" phrases:** ensuring reliability, showcasing features, highlighting capabilities, enabling seamless integration, fostering collaboration.

**Filler openers:** in today's fast-paced world, in the ever-evolving landscape, at the end of the day, needless to say, when it comes to.

**Phrasal verbs (prefer one plain verb):** spin up -> start, tear down -> remove, kick off -> start, reach out -> contact.

## Structural Patterns to Cut

**Rule of three.** AI writing pads with three parallel items where one or two would do. Examples: "clear, concise, and compelling", or "the good, the bad, and the ugly". Keep the items that carry real content. Cut the rest.

**Negative parallelism.** "It is not just X, it is Y." "This is not about X; it is about Y." The construction sounds profound and says little. State the point directly.

**Elegant variation.** Calling one thing by several names to avoid repetition ("the device ... the apparatus ... the unit"). This is the opposite of STE's one-name-per-thing rule. Pick one name and repeat it.

**Vague attribution.** "Many experts believe", "it is widely regarded as", "some say". Name the source or drop the claim.

**False range.** "From startups to enterprises", "from novices to experts" used to imply completeness without content. Cut it or replace with the real scope.

**Editorializing conclusions.** A closing paragraph that summarizes challenges and future prospects for a topic that did not need one. If the piece does not need a conclusion, do not add one.

**Hedging stacks.** "may potentially", "might possibly", "could perhaps in some cases". One qualifier at most. Better still, state the condition: "The API returns an error when the token expires."

## Formatting Patterns to Cut

- Excessive boldface, especially bold on a phrase in every bullet.
- Bullet lists where prose would read better. Bullets are for genuine lists, not for chopping up an argument.
- Title Case In Section Headings where sentence case is the house style.
- Em-dash overuse. STE and Strunk both allow the dash, but a machine reaches for it constantly. Use it with intent.
- Emoji as decoration.

## Before / After

| Slop | Clean |
| --- | --- |
| This commit implements the functionality for ensuring that user authentication is properly handled, showcasing robust error handling capabilities. | Add user authentication with error handling. |
| This groundbreaking feature leverages cutting-edge technology to deliver a seamless experience, fostering better engagement. | This feature updates the dashboard in real time over a WebSocket connection. |
| It is important to note that the API might potentially return an error in certain situations. | The API returns an error when the token expires. |
| Our solution is not just a tool, it is a comprehensive platform that empowers teams to unlock their full potential. | The tool tracks issues and assigns them to owners. |

## The Honest Limit

This filter fixes the form of slop: the words, the padding, the formatting. It cannot supply substance. If a paragraph is empty after you cut the slop, the problem was the idea, not the prose. Write the true thing instead.
