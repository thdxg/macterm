FROM nginx:1.27-alpine

# Static site assets
COPY index.html styles.css script.js /usr/share/nginx/html/
COPY assets/ /usr/share/nginx/html/assets/

# Server config as a template: the official image runs envsubst over
# /etc/nginx/templates/*.template at container start, writing the result to
# /etc/nginx/conf.d/. NGINX_ENVSUBST_FILTER limits substitution to GITHUB_TOKEN
# so nginx's own runtime $variables ($uri, $host, …) are left untouched.
COPY default.conf.template /etc/nginx/templates/default.conf.template
ENV NGINX_ENVSUBST_FILTER="GITHUB_TOKEN"

# Provided at runtime (e.g. `docker run -e GITHUB_TOKEN=…`); a fine-grained PAT
# with public read access is enough. If unset, the token expands to an empty
# string and the proxy falls back to unauthenticated (60/hr) requests.
ENV GITHUB_TOKEN=""

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://localhost/ >/dev/null 2>&1 || exit 1
