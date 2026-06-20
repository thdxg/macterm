export async function onRequest(context) {
  const { request, env, params } = context;

  // Reconstruct the GitHub API URL
  // E.g., /api/gh/repos/thdxg/macterm becomes https://api.github.com/repos/thdxg/macterm
  const targetPath = (params.path || []).join('/');
  const githubUrl = `https://api.github.com/${targetPath}`;

  // Copy the incoming request but change the destination
  const githubRequest = new Request(githubUrl, {
    method: request.method,
    // We do not forward the incoming headers/cookies directly to avoid conflicts
  });

  // Inject the required headers, including the secure token from the environment
  if (env.GITHUB_TOKEN) {
    githubRequest.headers.set('Authorization', `Bearer ${env.GITHUB_TOKEN}`);
  }
  githubRequest.headers.set('User-Agent', 'macterm-website');
  githubRequest.headers.set('Accept', 'application/vnd.github+json');

  // Fetch the data from GitHub
  const response = await fetch(githubRequest);

  // Reconstruct the response to add caching headers (similar to proxy_cache_valid 200 60s)
  const newResponse = new Response(response.body, response);
  if (response.ok) {
    newResponse.headers.set('Cache-Control', 'public, max-age=60');
  }

  return newResponse;
}
