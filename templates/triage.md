# Triage failing tests and propose fixes

Find the most recent failing test output (check runs/ for headless run
logs, or run the test suite if no recent log exists). For each failure:
identify the failing test name and location, trace the root cause through
the code, and propose a minimal fix. Propose only — do not apply changes.
For each finding, report: test name, file path, line number, root cause,
and the proposed fix with exact code.
