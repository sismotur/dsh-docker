# Add missing type annotations

Scan the codebase for functions, variables, and parameters missing type
annotations. Add annotations where the type can be inferred from context.
For cases where the type is ambiguous or could be multiple types, flag
them with a comment instead of guessing. Do not change runtime behavior —
only add types. End with a summary: annotations added, ambiguous cases
flagged.
