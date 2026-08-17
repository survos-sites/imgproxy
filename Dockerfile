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

# ---------------------------------------------------------------------------
# Opinionated, NON-SECRET configuration lives here, in the public image.
#
# The design: this image carries the opinion; Dokku config carries only secrets
# and the handful of values that are genuinely per-deployment (endpoints,
# bucket, region). Someone else can adopt this image by setting their own keys
# and endpoint, and inherit all the tuning below.
#
# It had drifted: 57 keys were in `dokku config`, of which only ~12 are secrets
# or endpoints. Everything below was living on one server instead of in git —
# including ONNX model paths that only make sense *inside* this image.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# PRESETS — the canonical, versioned list. Apps MUST request `pr:<name>` and
# never inline `rs:...` options.
#
# Why this matters: every distinct option string is its own cache key, in both
# Cloudflare and the S3 result cache. When each app spells out its own
# dimensions they drift apart and the cache fragments — measured 2026-08-17,
# apps were requesting rs:fit:400:400, rs:fill:800:600 and rs:fit:600:400 while
# the server presets (512/1280/3000) went completely unused. Four preset names
# is four cache keys per source image; ad-hoc options are unbounded.
#
# These MUST stay identical to SurvosImgproxyBundle::DEFAULT_PRESETS in
# mono/bu/imgproxy-bundle — that is the client half of the same contract. The
# bundle expands presets client-side (deliberately: it keeps the bundle usable
# against any imgproxy without server config), so these definitions and the
# option ORDER below (rs / q / sm / f) mirror exactly what the builder emits.
# Verify with:  bin/presets --full
#
# `archive` is 0:0 on purpose — no resize, full source resolution, sm:0 to keep
# EXIF/IPTC/XMP. OpenSeadragon zooms this derivative, so capping it to a fixed
# size would silently degrade the viewer below what the scan actually contains.
#
# ⚠️ Changing a preset's definition silently invalidates every cached
# derivative under that name. Settle these before the thumbnail-seeding job
# populates the cache at scale.
#
# Format is pinned to webp deliberately, NOT left to IMGPROXY_AUTO_WEBP.
# Cloudflare does not vary its cache on `Accept`, so content negotiation
# behind this CDN can serve a client a format it cannot decode. Explicit
# format = deterministic cache key. Revisit AUTO_AVIF only after verifying
# Vary handling end to end (~25% smaller than webp at matched quality, but
# ~93-95% browser support vs webp's ~97%).
#
# Measured on our own images at matched SSIM (2026-08-17): webp is 20-33%
# smaller than jpeg, and the advantage grows with quality — so it earns its
# place most on `archive`, least on `thumb`.
# ---------------------------------------------------------------------------
# THIS LINE IS THE SINGLE SOURCE OF TRUTH. Do not mirror it into a second file
# — a duplicated list is the drift this whole block exists to prevent. imgproxy
# has no endpoint that reports its presets, so consumers read it back off the
# image instead (see bin/presets).
# The server carries the UNION of every preset any app uses, so `pr:<name>` is
# always resolvable no matter which app asks. The five `fit` presets come from
# the bundle default; the three `fill` presets are openfoto/fotoStory home-page
# chrome (cover-crop, edge-to-edge, matching the CSS object-fit:cover they sit
# in) and are declared in its config/packages/survos_imgproxy.yaml.
#
# Note that an app's `survos_imgproxy.presets` REPLACES the bundle default
# wholesale rather than merging — which is why openfoto restates all five fit
# presets verbatim. bin/check-presets-sync validates every app config too, so a
# stale restatement there is caught rather than silently diverging.
ENV IMGPROXY_PRESETS="tiny=rs:fit:200:200:0:0/q:70/f:webp,thumb=rs:fit:400:400:0:0/q:80/f:webp,observe=rs:fit:512:512:0:0/q:80/f:webp,display=rs:fit:600:400:0:0/q:80/f:webp,archive=rs:fit:0:0:0:0/q:88/sm:0/f:webp,card=rs:fill:800:600:0:0/q:82/f:webp,hero=rs:fill:2200:1100:0:0/q:82/f:webp,about=rs:fill:900:1100:0:0/q:82/f:webp"

# Serving, limits and behaviour
ENV IMGPROXY_BIND=":8080" \
    IMGPROXY_WORKERS=16 \
    IMGPROXY_CONCURRENCY=4 \
    IMGPROXY_MALLOC=malloc \
    IMGPROXY_LOG_LEVEL=info \
    IMGPROXY_TIMEOUT=120 \
    IMGPROXY_DOWNLOAD_TIMEOUT=30 \
    IMGPROXY_READ_REQUEST_TIMEOUT=30 \
    IMGPROXY_KEEP_ALIVE_TIMEOUT=120 \
    IMGPROXY_MAX_BUFFER_SIZE=67108864 \
    IMGPROXY_MAX_WIDTH=4096 \
    IMGPROXY_MAX_HEIGHT=4096 \
    IMGPROXY_MAX_SRC_RESOLUTION=500 \
    IMGPROXY_ALLOWED_FORMATS="jpeg,png,webp,avif" \
    IMGPROXY_AUTO_WEBP=true \
    IMGPROXY_AUTO_ROTATE=true \
    IMGPROXY_STRIP_METADATA=false

# Security. REQUIRE_SIGNATURE is the reason IMGPROXY_KEY/SALT must match what
# zm/mediary/md sign with — see the imgproxy-signed-url-pattern note.
ENV IMGPROXY_REQUIRE_SIGNATURE=true \
    IMGPROXY_BLOCK_LOOPBACK=true \
    IMGPROXY_BLOCK_LOCAL_NETWORKS=true \
    IMGPROXY_BLOCK_PRIVATE_NETWORKS=true \
    IMGPROXY_LICENSE_DEVELOPMENT_MODE=false

# Storage mode. The endpoint, region, bucket and credentials stay in Dokku
# config — those are per-deployment. That we USE S3 is part of the opinion.
ENV IMGPROXY_USE_S3=true \
    IMGPROXY_CACHE_USE=s3

# Pro ML features. These paths exist only inside this image, so keeping them in
# Dokku config was actively wrong — they would be meaningless anywhere else.
ENV IMGPROXY_AUTOQUALITY_JPEG_NET=/opt/imgproxy/share/models/autoquality_jpeg.onnx \
    IMGPROXY_AUTOQUALITY_WEBP_NET=/opt/imgproxy/share/models/autoquality_webp.onnx \
    IMGPROXY_AUTOQUALITY_AVIF_NET=/opt/imgproxy/share/models/autoquality_avif.onnx \
    IMGPROXY_AUTOQUALITY_JXL_NET=/opt/imgproxy/share/models/autoquality_jxl.onnx \
    IMGPROXY_CLASSIFICATION_NET=/opt/imgproxy/share/models/classify.onnx \
    IMGPROXY_CLASSIFICATION_CLASSES=/opt/imgproxy/share/models/classify.names \
    IMGPROXY_CLASSIFICATION_NET_SIZE=224 \
    IMGPROXY_CLASSIFICATION_LAYOUT=nhwc \
    IMGPROXY_CLASSIFICATION_NORMALIZATION=none \
    IMGPROXY_CLASSIFICATION_THRESHOLD=0.5 \
    IMGPROXY_OBJECT_DETECTION_NET=/opt/imgproxy/share/models/yolox-tiny-face.onnx \
    IMGPROXY_OBJECT_DETECTION_CLASSES=/opt/imgproxy/share/models/yolox-tiny-face.names \
    IMGPROXY_OBJECT_DETECTION_NET_SIZE=640 \
    IMGPROXY_OBJECT_DETECTION_CONFIDENCE_THRESHOLD=0.4

# ---------------------------------------------------------------------------
# STAYS in `dokku config:set` — secrets and per-deployment values:
#
#   IMGPROXY_KEY, IMGPROXY_SALT              signing secrets
#   IMGPROXY_LICENSE_KEY                     Pro licence
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY object storage credentials
#   IMGPROXY_CACHE_ACCESS_KEY_ID/_SECRET_ACCESS_KEY
#   IMGPROXY_S3_ENDPOINT, IMGPROXY_S3_REGION
#   IMGPROXY_CACHE_*_ENDPOINT/_REGION/_BUCKET/_PATH_PREFIX
#   *_ENDPOINT_USE_PATH_STYLE                provider-specific (false for Hetzner)
#
# APPLIED 2026-08-17. The 39 superseded keys were unset and the presets file
# unmounted, so `dokku config` now holds only the 18 secrets/endpoints listed
# above and `dokku storage:list imgproxy` is empty. Verified end-to-end: bad
# signature still 403s, and pr:thumb/display/archive returned the expected
# pixel dimensions from a forced cache miss.
#
# Dokku config OVERRIDES image ENV, so if any of the keys set above are ever
# re-added with `config:set` they will silently win over this file again.
#
# imgproxy now has NO mounts and is fully stateless — which is what makes
# relocating it (e.g. to fsn1, next to the object storage — survos/docker#6) a
# redeploy rather than a migration.
#
# NOTE: IMGPROXY_CACHE_ENDPOINT/_REGION and IMGPROXY_CACHE_S3_ENDPOINT/_S3_REGION
# are BOTH set on the host with identical values — two naming generations kept
# for safety. Resolve against the v4.0.12 docs rather than copying both forward.
# ---------------------------------------------------------------------------

# imgproxy listens here by default (IMGPROXY_BIND=:8080); Dokku maps 80->8080
# via `dokku ports:add imgproxy http:80:8080`.
EXPOSE 8080
