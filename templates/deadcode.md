# Find unused and dead code

Find code that is likely unused or dead in this repository. Check for:
exported functions and types never imported elsewhere, unreferenced files,
unreachable code branches, commented-out code blocks, and unused
dependencies. For each finding, report: file path, line number, the dead
code, and evidence it is unused (no references found). List findings
before making any changes. Do not delete anything unless explicitly asked.
