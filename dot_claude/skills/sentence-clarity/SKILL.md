---
name: sentence-clarity
description: Use when editing prose for readability - detects em dash overuse, overly long sentences, and choppy rhythm. Use after drafting or when text feels cluttered.
---

# Sentence Clarity

Focused editing for sentence-level readability issues that fragment attention or exhaust readers.

## When to Use

- Editing blog posts, documentation, or any prose
- Text feels cluttered or hard to follow
- Paragraphs contain multiple em dashes
- Sentences exceed 30 words

## The Em Dash Rule

**Limit: 1 em dash pair per paragraph, 3 total per post.**

Em dashes interrupt flow. Each one says "pause here, hold this thought." Multiple interruptions per sentence exhaust working memory.

### Replacement Patterns

| Pattern | Replace With |
|---------|--------------|
| `X—unlike Y—does Z` | `Unlike Y, X does Z` |
| `The thing—which does X—also Y` | `The thing does X. It also Y` |
| `A—B—C` (list) | `A, B, and C` or `A: B and C` |
| `Result—measured in X—improved` | `Result improved (measured in X)` |
| `Aside—clarification—continuation` | Move aside to own sentence |

### When Em Dashes Work

- Single dramatic interruption for emphasis
- Setting off a list when commas would confuse
- Attributing a quote

```
OK:  "The result—a 40% improvement—exceeded expectations."
BAD: "The result—measured in milliseconds—improved—though not as much as hoped—by about 40%."
```

## The Long Sentence Rule

**Limit: 25 words per sentence. Hard ceiling: 35 words.**

Long sentences force readers to hold too many concepts. Break at natural joints.

### Breaking Points

1. **At "and" or "but"** - Often signals a new thought
2. **At "which" or "that"** - Relative clauses can standalone
3. **At semicolons** - Already a soft break
4. **Before examples** - "For example" starts a new sentence

### Before/After

```
BEFORE (42 words):
"The algorithm processes text by breaking it down into tokens and then
analyzing each token's relationship to its neighbors, and this process
yields accurate results that can be applied to sentiment analysis,
named entity recognition, and machine translation."

AFTER (3 sentences, avg 14 words):
"The algorithm breaks text into tokens and analyzes how each relates
to its neighbors. This process yields accurate results. Applications
include sentiment analysis, named entity recognition, and translation."
```

## Quick Scan Checklist

1. Count em dashes in paragraph - more than 2? Rewrite.
2. Any sentence over 30 words? Break it.
3. Three+ commas in one sentence? Likely too complex.
4. Reading aloud causes breathlessness? Too long.

## Process

1. **Scan for em dashes** - Count per paragraph
2. **Measure longest sentences** - Flag >25 words
3. **Apply replacement patterns** - Use table above
4. **Read aloud** - Final rhythm check
