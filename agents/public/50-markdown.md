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
