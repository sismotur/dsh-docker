# Third-party notices

This repository is an **independent** Docker packaging and hardening project.
It is **not** an official DeepSeek product and is **not** a git fork of the
DeepSeek Harness monorepo.

## DeepSeek Harness (`dsh`)

This project downloads and runs [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
via the npm package [`@deepseek-ai/dsh`](https://www.npmjs.com/package/@deepseek-ai/dsh)
(and related `@deepseek-ai/*` packages) at **image build time**
(`npm ci` from `global-tools/package-lock.json`).

Those components are licensed under the MIT License:

```
MIT License

Copyright (c) 2026 DeepSeek

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Upstream repository: https://github.com/deepseek-ai/deepseek-harness  
Upstream third-party notices (if present in that repo):
https://github.com/deepseek-ai/deepseek-harness/blob/master/THIRD_PARTY_NOTICES.md

When you **distribute container images** built from this Dockerfile, the image
layers include npm-installed DeepSeek packages. Keep this NOTICE (and the MIT
text above) with any such distribution.

## Other runtime dependencies

- **Node.js** base image and OS packages: see their respective licenses
  (Debian/Node distribution terms).
- **LiteLLM** (`ghcr.io/berriai/litellm`): separate image; see BerriAI/LiteLLM
  licensing.
- **MCP memory server**, **pnpm**, and other npm deps: licenses as declared on
  npm for each package version pinned in the lockfiles.

This project's **original** files (Docker/Compose, scripts, patches, agent
packs, docs) are licensed under the MIT License in `LICENSE` (copyright
Felipe Santi), unless a file says otherwise.
