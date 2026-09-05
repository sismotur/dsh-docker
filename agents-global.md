# Global Agent Instructions

These rules apply to every session. Project-level `AGENTS.md` files in the
workspace override or supplement these.

## Think before coding

State assumptions explicitly. If uncertain, ask. If multiple interpretations
exist, present them — do not pick silently. If a simpler approach exists, say
so. Push back when warranted. If something is unclear, stop and ask.

**Simplicity first.** Minimum code that solves the problem. No features beyond
what was asked. No abstractions for single-use code. No speculative
flexibility or configurability. No error handling for impossible scenarios. If
200 lines could be 50, rewrite.

**Surgical changes.** Touch only what you must. Do not improve adjacent code,
comments, or formatting. Do not refactor things that are not broken. Match
existing style even if you would do it differently. If you notice unrelated
dead code, mention it — do not delete it. Remove only imports/variables/functions
that your changes made unused. Every changed line should trace directly to the
request.

**Goal-driven execution.** Transform tasks into verifiable goals. Write tests
that reproduce bugs, then fix them. Ensure tests pass before and after
refactors. For multi-step tasks, state a brief plan with verification checks per
step. These guidelines bias toward caution over speed — use judgment for trivial
tasks.

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

## JPL-inspired coding standards

Follow these guidelines, not blindly — use judgment for trivial tasks.

1. Restrict to simple control flow. No `goto`, `setjmp()`, `longjmp()`.
2. Declare all variables at the top of a function. No mixing declarations and code.
3. Minimum two runtime checks per function (pre- and post-conditions: validate pointers, array bounds, return values).
4. Use a standard naming convention for variables and functions.
5. Use preprocessor for constants only. Never `#define` for macros. Use `const` variables. Avoid function-like macros.
6. No dynamic memory allocation after initialization. Allocate all memory at startup. `malloc()`/`free()` can fail, fragment, leak, or corrupt heap.
7. No recursion. Unbounded recursion causes stack overflow.
8. Limit function length to 100 lines.
9. Minimum 80% code coverage with unit testing.
10. Compile with all warnings enabled. Treat warnings as errors.

## Python dependency security

When updating Python dependencies in `requirements.txt`, always verify CVEs
using pip-audit or the NIST NVD. Pin transitive dependencies with known CVEs
and annotate each pinned version with a comment explaining which CVE it
addresses (e.g. `# fixes CVE-XXXX-XXXXX`). Never update a package without
checking its changelog for security advisories.

## Markdown compliance

When generating, revising, or formatting Markdown, strictly adhere to CommonMark
and GitHub Flavored Markdown (GFM) standards:

- Proper heading syntax (`#`, `##`) with a single space after the hash.
- Lists (`-`, `*`, `1.`) with correct indentation (2-4 spaces for sub-items).
- Fenced code blocks with language tags (e.g. ` ```python `).
- Escape special characters (`\*`, `\_`, `\#`, `\[`) when used literally.
- Valid link syntax: `[text](url)` with optional title.
- Valid image syntax: `![alt text](url)` with descriptive alt text.
- Valid GFM tables with header separators (`|---|`).
- Wrap paragraphs at ≤80 characters unless readability suffers.
- No deprecated or nonstandard extensions (no raw HTML unless explicitly allowed).
- Validate internal links and reference definitions.
- Output must render identically across all CommonMark-compliant renderers.
- Never introduce custom syntax outside CommonMark or GFM.

## Ollama local settings

The local Ollama instance uses `OLLAMA_NUM_PARALLEL=3` (up to 3 concurrent
requests) and `OLLAMA_KV_CACHE_TYPE=q8_0`. The API is at
`http://localhost:11434`. Do not suggest changing these settings unless
explicitly asked.

## Google Cloud — inventrip project

- Project ID: `voltaic-azimuth-105813`
- Project name: `inventrip`
- Project number: `835922139021`
- User: `fsanti@sismotur.com`

Infrastructure:

- **PostgreSQL**: production `inventrip-postgres-f24a92b2`, staging
  `inventrip-postgres-staging-ca1cf38d`.
- **Kubernetes**: production cluster `inventrip-gke-production`, staging
  `inventrip-gke-staging`.
- **Redis**: MemoryStore instance `inventrip-memorystore`.
- Network with load balancer, firewall, one external IP.

When running `gcloud` or `kubectl`, always default to project
`voltaic-azimuth-105813`. For `kubectl`, production cluster is
`inventrip-gke-production`, staging is `inventrip-gke-staging`. Always confirm
target environment (production vs staging) before suggesting commands that
modify cluster state.

## Database safety

The production system is a Google Cloud instance named
`inventrip-postgres-f24a92b2`. Do not run DDL queries in the production
environment.

For the inventrip and signing PostgreSQL databases: use `gcloud sql connect`
for direct access, always specifying `--user=<user>` and `--database=<db>`.

For migrations and schema changes, apply them **only after human validation** to
staging (`inventrip-postgres-staging-ca1cf38d`) first and validate. Never apply
DDL or data modification commands (INSERT, UPDATE, DELETE) directly to
production.

## Git commits

GitHub commits are made by human users. Never credit AI for them.

## iOS and Android dependency management

- **iOS** (`inventrip_ios2`): uses CocoaPods (`Podfile`/`Pods/`). Always use
  `pod install` and `pod update` for dependency management. Never Swift Package
  Manager.
- **Android** (`inventrip_android2`): uses Gradle with Kotlin DSL
  (`build.gradle.kts`). Always use Gradle wrapper (`./gradlew`) instead of a
  global `gradle` command.

## sismotur.com website

Hosted on Google Cloud Platform, project ID: `sismotur-tools`. Based on
WordPress technology.

Virtual Machine:

- Name: `wordpress-website-sismotur-vm`
- Zone: `europe-north1-b`
- Internal IP: `10.166.0.2`
- External IP: `34.88.69.68`

A firewall rule in Cloudflare called "Allow WordPress admin-ajax" must be
enabled to edit entries using Elementor.
