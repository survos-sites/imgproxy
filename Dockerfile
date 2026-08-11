# imgproxy Pro (ML build) — the FROM tag IS our version pin (in git). Bump it,
# commit, redeploy. Pulling this image requires `docker login docker.imgproxy.pro`
# with a valid Pro license on whatever host builds it (Dokku included) — the
# credentials already exist on the current shared host since it's running this
# same image today; they need to be present wherever `dokku git:from-image` /
# `git push dokku` actually builds.
#
# The legacy service may run a different version until cutover. Confirm the
# deployed staging image before switching production traffic.
#
# Upgrade plan: move to the first 4.1.x beta once per-preset S3 result-cache
# TTLs ship (on imgproxy's 4.1 roadmap) — today caching is all-or-nothing via
# IMGPROXY_CACHE_USE, no per-preset control.
FROM docker.imgproxy.pro/imgproxy:v4.0.12-ml

# imgproxy listens here by default (IMGPROXY_BIND=:8080); Dokku maps 80->8080
# via `dokku ports:add imgproxy http:80:8080`.
EXPOSE 8080
