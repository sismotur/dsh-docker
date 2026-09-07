# Code review of uncommitted changes

Review all uncommitted changes in this repository. For each changed file,
check for: security vulnerabilities (injection, auth bypass, secrets in
code), error handling gaps, resource leaks, race conditions, and style
consistency with the surrounding code. Block the review on any critical
or high-severity finding. For each finding, report: severity, file path,
line number, the issue, and a recommended fix. End with a verdict:
APPROVE, REQUEST CHANGES, or BLOCK.
