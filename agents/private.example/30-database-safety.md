## Database safety

<!-- Fill in agents/private/ with real instance names. Not seeded from example. -->

Do not run DDL on production. Use `gcloud sql connect` with explicit
`--user=` and `--database=`. Apply migrations to staging first after human
validation. Never INSERT/UPDATE/DELETE directly on production without approval.
