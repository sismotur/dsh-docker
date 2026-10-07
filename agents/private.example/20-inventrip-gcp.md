## Google Cloud — project context

<!-- Fill in agents/private/ with real project id, clusters, email. Not seeded from example. -->

- Project ID: `YOUR_GCP_PROJECT_ID`
- Project name: `YOUR_PROJECT_NAME`
- User: `you@example.com`

Infrastructure:

- **PostgreSQL**: production `YOUR_SQL_PROD`, staging `YOUR_SQL_STAGING`.
- **Kubernetes**: production `YOUR_GKE_PROD`, staging `YOUR_GKE_STAGING`.
- **Redis**: `YOUR_MEMORYSTORE`.

When running `gcloud` or `kubectl`, default to the project above. Always confirm
target environment (production vs staging) before commands that modify cluster
state.
