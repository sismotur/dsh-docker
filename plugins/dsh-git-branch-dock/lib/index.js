/**
 * Host half: GET /git-branch-dock/branch → { branch, project, label, root }.
 *
 * Reports the git branch of the *mounted project* at /workspace (e.g. inventrip_api),
 * not the dsh-docker packaging repo. GIT_CEILING_DIRECTORIES stops discovery from
 * walking above /workspace (empty default workspace has no .git and must return null).
 */
import { execFile } from "node:child_process";
import { access } from "node:fs/promises";
import { dirname, join } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export const name = "dsh-git-branch-dock";
export const inject = ["webServer"];

const WORKSPACE = "/workspace";
const PATH = "/git-branch-dock/branch";

async function pathExists(p) {
  try {
    await access(p);
    return true;
  } catch {
    return false;
  }
}

/**
 * @param {string} cwd
 * @returns {Promise<{ branch: string, toplevel: string } | null>}
 */
async function readGit(cwd) {
  // Prevent git from walking above the workspace mount (e.g. host monorepo
  // layout when only a subfolder is bind-mounted without its own .git).
  const ceiling = dirname(cwd);
  const env = {
    ...process.env,
    GIT_CEILING_DIRECTORIES: ceiling,
  };
  const opts = { timeout: 4000, maxBuffer: 64 * 1024, env };

  try {
    const { stdout: topOut } = await execFileAsync(
      "git",
      ["-C", cwd, "rev-parse", "--show-toplevel"],
      opts,
    );
    const toplevel = String(topOut || "").trim();
    if (!toplevel) return null;

    // Only accept a repo rooted at the workspace (or a nested repo under it).
    // Reject anything outside /workspace.
    const normTop = toplevel.replace(/\/+$/, "") || toplevel;
    const normCwd = cwd.replace(/\/+$/, "") || cwd;
    if (normTop !== normCwd && !normTop.startsWith(normCwd + "/")) {
      // toplevel is a parent outside the mount — should be blocked by ceiling,
      // but guard anyway.
      return null;
    }

    const { stdout: brOut } = await execFileAsync(
      "git",
      ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
      opts,
    );
    let branch = String(brOut || "").trim();
    if (!branch) return null;
    if (branch === "HEAD") {
      const { stdout: sha } = await execFileAsync(
        "git",
        ["-C", cwd, "rev-parse", "--short", "HEAD"],
        opts,
      );
      const short = String(sha || "").trim();
      branch = short ? `detached@${short}` : null;
      if (!branch) return null;
    }
    return { branch, toplevel: normTop };
  } catch {
    return null;
  }
}

/** Project display name: WORKSPACE_NAME env (set by run-dsh mount) or folder basename. */
async function projectName(cwd) {
  const fromEnv = (process.env.WORKSPACE_NAME || "").trim();
  if (fromEnv && fromEnv !== "workspace") return fromEnv;
  // Prefer basename of real git toplevel when it is nested under /workspace
  try {
    const git = await readGit(cwd);
    if (git && git.toplevel && git.toplevel !== cwd) {
      const base = git.toplevel.split("/").filter(Boolean).pop();
      if (base) return base;
    }
  } catch {
    /* ignore */
  }
  // workspace.json title as last resort
  try {
    const raw = await import("node:fs/promises").then((fs) =>
      fs.readFile("/data/storages/workspace.json", "utf8"),
    );
    const j = JSON.parse(raw);
    const tables = j?.tables?.workspaces || {};
    for (const id of Object.keys(tables)) {
      const w = tables[id];
      if (w?.path === cwd && typeof w.title === "string" && w.title.trim()) {
        const t = w.title.trim();
        if (t !== "workspace") return t;
      }
    }
  } catch {
    /* ignore */
  }
  // basename of cwd if it looks like a project name
  const base = cwd.split("/").filter(Boolean).pop();
  if (base && base !== "workspace") return base;
  return null;
}

function sendJson(res, status, body) {
  const payload = JSON.stringify(body);
  res.statusCode = status;
  res.setHeader("content-type", "application/json; charset=utf-8");
  res.setHeader("cache-control", "no-store");
  res.end(payload);
}

export function apply(ctx) {
  ctx.effect(
    () =>
      ctx.webServer.register({
        kind: "exact",
        path: PATH,
        handler: async (req, res) => {
          if (req.method !== "GET" && req.method !== "HEAD") {
            res.statusCode = 405;
            res.setHeader("allow", "GET, HEAD");
            res.end();
            return;
          }
          if (!(await pathExists(WORKSPACE))) {
            sendJson(res, 200, {
              branch: null,
              project: null,
              label: null,
              root: WORKSPACE,
              separator: " --- ",
            });
            return;
          }
          const git = await readGit(WORKSPACE);
          const project = await projectName(WORKSPACE);
          const branch = git?.branch ?? null;
          // label shown in footer: "inventrip_api @ development" or just branch
          let label = null;
          if (branch && project) label = `${project} @ ${branch}`;
          else if (branch) label = branch;
          sendJson(res, 200, {
            branch,
            project,
            label,
            root: WORKSPACE,
            toplevel: git?.toplevel ?? null,
            separator: " --- ",
            hasGit: Boolean(await pathExists(join(WORKSPACE, ".git"))),
          });
        },
      }),
    `dsh-git-branch-dock: GET ${PATH}`,
  );
}
