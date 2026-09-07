# Security audit of the codebase

Audit this repository for security issues. Check for: hardcoded secrets
and credentials, SQL injection (string-concatenated queries), command
injection (unsanitized shell calls), path traversal, unsafe
deserialization, missing authentication or authorization checks, insecure
cryptographic usage, and sensitive data in logs or error messages. For
each finding, report: severity (Critical, High, Medium, Low), file path,
line number, the vulnerability, and a recommended fix. Sort findings by
severity.
