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

# Presets. Previously ONLY in /mnt/volume-1/imgproxy-presets.conf, mounted to
# /etc/imgproxy/presets.conf via IMGPROXY_PRESETS_PATH. That file was untracked:
# losing it breaks every thumb/display/archive URL in zm, mediary and md.
ENV IMGPROXY_PRESETS="thumb=rs:fit:512:512:0:0/q:80/f:webp/sm:0,display=rs:fit:1280:1280:0:0/q:82/f:webp/sm:0,archive=rs:fit:3000:3000:0:0/q:88/f:webp/sm:0"

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
# Deploying this change means unsetting what it now supersedes, or the old
# values keep winning (Dokku config overrides image ENV):
#
#   dokku config:unset imgproxy IMGPROXY_PRESETS_PATH IMGPROXY_BIND \
#     IMGPROXY_WORKERS IMGPROXY_CONCURRENCY ... (all keys set above)
#   dokku storage:unmount imgproxy \
#     /mnt/volume-1/imgproxy-presets.conf:/etc/imgproxy/presets.conf
#
# After that imgproxy has NO mounts and is fully stateless — which is what makes
# relocating it (e.g. to fsn1, next to the object storage) a redeploy rather
# than a migration.
#
# NOTE: IMGPROXY_CACHE_ENDPOINT/_REGION and IMGPROXY_CACHE_S3_ENDPOINT/_S3_REGION
# are BOTH set on the host with identical values — two naming generations kept
# for safety. Resolve against the v4.0.12 docs rather than copying both forward.
# ---------------------------------------------------------------------------

# imgproxy listens here by default (IMGPROXY_BIND=:8080); Dokku maps 80->8080
# via `dokku ports:add imgproxy http:80:8080`.
EXPOSE 8080
