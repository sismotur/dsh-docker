## Python dependency security

When updating Python dependencies in `requirements.txt`, always verify CVEs
using pip-audit or the NIST NVD. Pin transitive dependencies with known CVEs
and annotate each pinned version with a comment explaining which CVE it
addresses (e.g. `# fixes CVE-XXXX-XXXXX`). Never update a package without
checking its changelog for security advisories.
