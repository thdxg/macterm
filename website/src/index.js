export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // Serve stats API
    if (url.pathname === '/api/stats') {
      return handleStats(request, env, ctx);
    }

    // Fallback: serve static assets
    return env.ASSETS.fetch(request);
  }
};

async function handleStats(request, env, ctx) {
  const REPO = "thdxg/macterm";
  const GITHUB_API = "https://api.github.com";

  const getHeaders = () => {
    const headers = new Headers({
      "User-Agent": "macterm-website",
      "Accept": "application/vnd.github+json"
    });
    if (env.GITHUB_TOKEN) {
      headers.set("Authorization", `Bearer ${env.GITHUB_TOKEN}`);
    }
    return headers;
  };

  // Fetch stars
  const repoPromise = fetch(`${GITHUB_API}/repos/${REPO}`, { headers: getHeaders() })
    .then(r => r.ok ? r.json() : null)
    .catch(() => null);

  // Fetch releases with pagination
  const fetchAllReleases = async () => {
    let page = 1;
    let allReleases = [];
    while (true) {
      try {
        const r = await fetch(`${GITHUB_API}/repos/${REPO}/releases?per_page=100&page=${page}`, {
          headers: getHeaders()
        });
        if (!r.ok) break;
        const data = await r.json();
        if (!Array.isArray(data) || data.length === 0) break;
        
        allReleases.push(...data);
        if (data.length < 100) break;
        page++;
      } catch {
        break;
      }
    }
    return allReleases;
  };

  const releasesPromise = fetchAllReleases();

  const [repo, releases] = await Promise.all([repoPromise, releasesPromise]);

  let totalDownloads = 0;
  let latestDmg = null;

  if (Array.isArray(releases)) {
    for (const rel of releases) {
      if (rel.assets) {
        for (const asset of rel.assets) {
          totalDownloads += (asset.download_count || 0);
        }
      }
    }

    const latest = releases.find(rel => rel && !rel.draft && !rel.prerelease);
    if (latest && latest.assets) {
      const dmg = latest.assets.find(a => a.name?.endsWith(".dmg"));
      if (dmg) {
        latestDmg = {
          name: dmg.name,
          url: dmg.browser_download_url
        };
      }
    }
  }

  const payload = {
    stars: repo?.stargazers_count || 0,
    downloads: totalDownloads,
    latestDmg: latestDmg
  };

  return new Response(JSON.stringify(payload), {
    headers: {
      "Content-Type": "application/json",
      // Cache the heavy aggregation result at the edge and browser for 1 hour
      "Cache-Control": "public, max-age=3600"
    }
  });
}
