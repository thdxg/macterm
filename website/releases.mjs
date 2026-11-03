// The release notes that the changelog page (/changelog) shows, from GitHub.
//
// The notes are written once, on the GitHub release, so the page reads them
// from there and never keeps a second copy in the repository. Only stable
// releases are listed: a beta or a tip build is a prerelease, and a draft is
// not published yet.
//
// Two callers, as for lastmod.mjs:
//
// - The image build should not ask GitHub itself. An anonymous request from a
//   shared CI address gets 60 requests an hour, and the build stage has no
//   token. So `node releases.mjs` runs on the host first, with GH_TOKEN or
//   GITHUB_TOKEN when there is one, and writes docs/releases.json, which rides
//   into the build context. The website workflow runs it before `podman build`,
//   and so do the `podman:build` and `dev` scripts.
// - build-docs.mjs reads that file. When it is absent, it calls
//   `fetchReleases` itself, so a plain `bun run build` in a checkout works too.
//
// The page goes stale when a release is published, edited or deleted, so the
// website workflow builds the site again on each of those events.

import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));

// Written next to the pages so that the Containerfile's `COPY website/ ./`
// carries it. Git ignores it.
export const RELEASES_FILE = join(here, "docs", "releases.json");

export const REPO = "thdxg/macterm";

// Returns the stable releases, newest first, with only the fields the page
// needs. Throws when GitHub does not answer, because a changelog that silently
// lists nothing is worse than a failed build.
export async function fetchReleases() {
  const token = process.env.GH_TOKEN || process.env.GITHUB_TOKEN;
  const headers = {
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
  };

  const releases = [];
  for (let page = 1; ; page++) {
    const url = `https://api.github.com/repos/${REPO}/releases?per_page=100&page=${page}`;
    const res = await fetch(url, { headers });
    if (!res.ok) {
      throw new Error(`GET ${url} returned ${res.status}: ${(await res.text()).slice(0, 200)}`);
    }
    const batch = await res.json();
    releases.push(...batch);
    if (batch.length < 100) break;
  }

  const stable = releases
    .filter((r) => !r.draft && !r.prerelease && r.published_at)
    .map((r) => ({
      tag: r.tag_name,
      publishedAt: r.published_at,
      url: r.html_url,
      body: (r.body || "").replace(/\r\n/g, "\n").trim(),
    }))
    .sort((a, b) => Date.parse(b.publishedAt) - Date.parse(a.publishedAt));

  if (!stable.length) {
    throw new Error(`${REPO} has no stable releases on GitHub`);
  }
  return stable;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const releases = await fetchReleases();
  writeFileSync(RELEASES_FILE, JSON.stringify(releases, null, 2) + "\n");
  console.log(`releases: wrote ${releases.length} releases to ${RELEASES_FILE}`);
}
