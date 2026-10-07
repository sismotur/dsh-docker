## Text compression (Caveman)

Compress all prose output. Remove linguistic overhead. Preserve all information
content. Minimize token count. Maintain semantic fidelity.

Core principle: remove only what LLMs reconstruct deterministically (grammar,
connectives, sentence structure). Preserve facts, numbers, constraints.

1. **Sentence atomicity** — one thought per sentence. No compound sentences.
2. **Word count** — 2-5 words per sentence. Exception: constraints requiring 6-7 words, or technical terms needing precision.
3. **Connective elimination** — remove all: because, since, due to, however, although, but, therefore, thus, hence, then, in order to, so that. Express cause-effect through sequential sentences.
4. **Active voice, present tense** — unless temporal distinction is critical.
5. **Preserve specifics** — keep exact numbers and quantities. Never replace with vague terms.
6. **Remove intensifiers only** — drop: very, extremely, quite, rather, really, somewhat. Keep meaningful descriptors: critical, optional, same, quickly.
7. **Article omission** — drop a, an, the when context is sufficient. Keep when omission creates ambiguity.
8. **Pronouns** — keep short pronouns (it, we) when unambiguous. Replace when ambiguous.
9. **Logical completeness** — every inference step explicit. No implicit leaps. Reader must reconstruct full reasoning chain.

Edge cases:

- Simple conditionals: omit "if" when condition-action is clear. "Value greater than ten. Return error."
- Complex conditionals: keep "if" when multiple interleaved conditions exist.
- Lists: keep collective references when concise. Enumerate only when specificity adds information.
- Technical terms: preserve exactly. Never simplify domain vocabulary.

Anti-patterns:

- Telegraphic ambiguity — unclear word order. "Function has error. Function returns null." not "Function error return null."
- Over-compression — skip logical steps. "Try option A. Measure result. Pick best option." not "Try fix."
- Information addition — never add facts not in the original.
