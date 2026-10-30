// The `lastmod` of every sitemap entry, from git.
//
// A page's lastmod is the commit date of its source: docs/pages/<file>.md for a
// docs page, public/index.html for the landing page. The file's mtime is no
// use: `git checkout` sets it, and the image build copies a fresh clone, so
// every page would claim to have changed on every deploy. Google discounts a
// lastmod that behaves that way, and a discounted lastmod is worth less than
// none, because it also costs the signal on the pages that really changed.
//
// Two callers:
//
// - build-docs.mjs imports `lastModifiedDates` and asks git directly, which
//   covers `bun run build` in a checkout.
// - The image build has no git history (the Containerfile copies website/ and
//   assets/ only), so `node lastmod.mjs` runs on the host first and writes the
//   dates to docs/lastmod.json, which rides into the build context. The
//   website workflow runs it before `podman build`, and so does the
//   `podman:build` script. build-docs.mjs reads the file only when git cannot
//   answer, so a stale file left in a checkout never wins over git.
//
// Both refuse a date from the edge of a shallow clone. At that edge, `git log
// -1 -- <file>` names the oldest commit the clone has, which is the commit that
// the clone was cut at and not the commit that changed the page. With
// `fetch-depth: 1`, that is one commit for every file, which is the
// "everything changed today" lie again. The workflow checks out with
// `fetch-depth: 0` for this reason. A clone that is cut deeper than the last
// change of every page is fine, and a developer's checkout often is one.

import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));

// Written next to the pages so that the Containerfile's `COPY website/ ./`
// carries it. Git ignores it.
export const LASTMOD_FILE = join(here, "docs", "lastmod.json");

// Source paths relative to website/. The landing page is hand-written, so it
// has no entry in docs/pages/.
export const LANDING_SOURCE = "public/index.html";
export const pageSource = (file) => `docs/pages/${file}`;

function git(args) {
  const run = spawnSync("git", args, { cwd: here, encoding: "utf8" });
  if (run.error) throw new Error(`git is not available: ${run.error.message}`);
  if (run.status !== 0) {
    throw new Error(`git ${args.join(" ")} failed: ${run.stderr.trim()}`);
  }
  return run.stdout.trim();
}

// The commits at the edge of a shallow clone. Git lists them in the `shallow`
// file of the repository (the common dir, so a worktree reads its main
// checkout's). A full clone has no such file.
function shallowBoundary() {
  const file = join(git(["rev-parse", "--path-format=absolute", "--git-common-dir"]), "shallow");
  if (!existsSync(file)) return new Set();
  return new Set(readFileSync(file, "utf8").split("\n").filter(Boolean));
}

// Returns { "<source>": "<ISO 8601, UTC>" } for every page source, or throws
// when git cannot answer honestly (no repository, no git, a page whose last
// change is beyond the edge of a shallow clone).
export function lastModifiedDates() {
  const boundary = shallowBoundary();

  const sources = [
    LANDING_SOURCE,
    ...readdirSync(join(here, "docs", "pages"))
      .filter((f) => f.endsWith(".md"))
      .sort()
      .map(pageSource),
  ];

  const dates = {};
  for (const source of sources) {
    // A source with uncommitted changes, or one that is not committed yet, is
    // newer than any commit, so it is "now". Production always builds from a
    // clean checkout, so this is only for a page in progress in a checkout.
    const dirty = git(["status", "--porcelain", "--", source]) !== "";
    const [hash, committed] = git(["log", "-1", "--format=%H %cI", "--", source]).split(" ");
    if (hash && boundary.has(hash)) {
      throw new Error(
        `the last change of ${source} is beyond the edge of this shallow clone, so its ` +
          "commit date is unknown. Fetch more history (fetch-depth: 0 in the workflow) first."
      );
    }
    const date = dirty || !committed ? new Date() : new Date(committed);
    dates[source] = date.toISOString();
  }
  return dates;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const dates = lastModifiedDates();
  writeFileSync(LASTMOD_FILE, JSON.stringify(dates, null, 2) + "\n");
  console.log(`lastmod: wrote ${Object.keys(dates).length} dates to ${LASTMOD_FILE}`);
}
