# Generate API endpoint documentation

Scan the codebase for all HTTP route handlers and API endpoints. For each
endpoint, document: HTTP method, path, authentication requirement, request
parameters (query, body, path) with types, response format and status
codes, and error cases. Write the documentation to API-docs.md, grouped by
resource or controller. Read the actual handler code — do not guess from
route names alone.
