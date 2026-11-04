# Writing style: STRICT, NON-NEGOTIABLE

The prose of AGENTS.md must read like a sober technical manual or engineering standard.
It must not read like an assistant reply, a product pitch, a tutorial with personality,
or a narrative with comic relief.

Voice and pacing:

- Use plain, declarative, impersonal prose. Use imperative mood for rules.
- State facts, constraints, and procedures directly. Do not create suspense, deliver
  punchlines, or end sections with a flourish.
- No quips, jokes, sarcasm, irony, whimsy, banter, or cinematic asides.
- No heroic, dramatic, or motivational language. No battle-tested, bulletproof,
  blazing, supercharge, unlock, or journey.
- No rhetorical questions. No narrator personality. No we, let's, or friendly direct
  address.
- No assistant filler: Great question, Certainly, Here's the thing, It's worth noting,
  In conclusion.
- No formulaic AI cadence: punchy fragment followed by explanation, rule-of-three
  lists for rhythm, contrastive reversals such as Not X. Y., repeated sentence
  openings, or paragraph-final zingers.
- Keep most sentences between 8 and 25 words. Avoid stacked short sentences for drama.
- Each paragraph has one purpose. No scene-setting, no narrative transitions, no
  closing moral.
- Use concrete technical nouns and verbs. Avoid vague adjectives and marketing adverbs.
- Headings must be plain labels, not cute titles.

House punctuation and typography:

- Do not use semicolons in prose.
- Do not use em dashes.
- Do not use decorative en dashes in prose.
- Do not use emoji, exclamation marks, or ellipses for effect.
- Prefer periods, commas, and colons. Use parentheses only for necessary qualification.
- Code, commands, flags, and SQL may contain punctuation required by syntax.

Acceptable examples:

- The application opens the database in read-only mode by default.
- Run `zig build -Dtarget=aarch64-linux-musl` to build for Termux.
- Write mode requires explicit confirmation.

Unacceptable examples:

- Think of it as Vim, but friendlier.
- One small switch. A much safer database.
- Let's dive into the build pipeline.
- Read-only by default. Because your data deserves it.

Do not claim semicolons or em dashes are absent from pre-2020 writing or proof of AI
prose. They are banned here as house style only.

Enforcement clause:

- Style is a hard gate, equal to a passing build.
- Before completion, audit every line for banned punctuation, quips, dramatic
  fragments, rhetorical questions, assistant filler, marketing language, and narrative
  pacing.
- If a violation is found, stop, quote the offending text, rewrite it, and re-check the
  whole document.
- Repeated violations require discarding the draft and starting over.
- No stylistic insubordination is tolerated. The rule admits no exceptions.
