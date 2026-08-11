# imgproxy — self-hosted image proxy (Dockerfile-driven Dokku app)

Signed on-the-fly image resizing/format conversion (imgproxy Pro, ML build) with
an S3-backed result cache. Serves `imgproxy.survos.com` for `zm`, `mediary`, and
`md` via the shared `survos/imgproxy-bundle` client (`ImgproxyUrlBuilder`,
`@survos/imgproxy/imgproxy` Stimulus controller).

**Why this repo exists:** imgproxy used to be installed/updated at the system
level on the shared dokku host by hand (sysadmin-mediated, no env var control
from our side, config drift not tracked in git). This repo makes it a normal
Dockerfile-driven Dokku app like `mattermost/` — direct `dokku config:set`
control, version pin in git, deploy via `git push dokku`.

## Versions (pinned)

- **Server:** `docker.imgproxy.pro/imgproxy:v4.0.12-ml` (`Dockerfile`). The `FROM`
  tag is the version pin — bump it, commit, redeploy. Verify the staging image
  before production cutover:
  `docker inspect <container> --format '{{.Config.Image}}'`.
- **Upgrade plan:** move to the first `4.1.x` beta once per-preset S3
  result-cache TTLs ship (on imgproxy's 4.1 roadmap). Today `IMGPROXY_CACHE_USE`
  is all-or-nothing — everything gets cached to S3, or nothing does, no
  per-preset control. Once available, this becomes a real reason to move off
  the pinned stable tag onto a beta.

## Local (docker-compose)

Uses the free `darthsim/imgproxy` image, not the Pro one — no license needed,
and local dev doesn't exercise the Pro-only ML/S3-result-cache features, just
resize/signing against plain source URLs.

```bash
cp .env.example .env   # fill in IMGPROXY_KEY / IMGPROXY_SALT for local signing
docker compose up -d
curl -I "http://localhost:8080/insecure/rs:fit:400:400/plain/https://example.com/some.jpg"
```

## Dokku deploy

Prerequisite: the host that builds this image needs `docker login
docker.imgproxy.pro` credentials for the Pro registry. These already exist on
the current shared host (it's running this same image today) — confirm they
carry over to wherever Dokku actually runs `docker build` for this app.

```bash
H=dokku@ssh.survos.com

ssh $H apps:create imgproxy

# Pull the REAL values off the currently-running container first --
# see .env.example for the full list of what's expected. Do not guess these,
# especially IMGPROXY_KEY/IMGPROXY_SALT (must match what zm/mediary/md send)
# and the S3/license values.
ssh $H config:set --no-restart imgproxy \
  IMGPROXY_KEY=<from current container> \
  IMGPROXY_SALT=<from current container> \
  IMGPROXY_LICENSE_KEY=<from current container> \
  IMGPROXY_USE_S3=true \
  IMGPROXY_S3_ENDPOINT=<...> \
  IMGPROXY_S3_REGION=<...> \
  IMGPROXY_S3_ALLOWED_BUCKETS=<...> \
  IMGPROXY_CACHE_USE=s3 \
  IMGPROXY_CACHE_S3_ENDPOINT=<...> \
  IMGPROXY_CACHE_S3_REGION=<...> \
  IMGPROXY_CACHE_BUCKET=<...> \
  IMGPROXY_WORKERS=<size for real load -- see note below>

ssh $H domains:set imgproxy imgproxy.survos.com
ssh $H ports:add  imgproxy http:80:8080

git remote add dokku dokku@ssh.survos.com:imgproxy
git push dokku main                              # builds the Dockerfile, deploys

ssh $H letsencrypt:set    imgproxy email tac@museado.org
ssh $H letsencrypt:enable imgproxy               # http-01, valid cert on origin
```

### Cutover — do NOT just flip DNS

`imgproxy.survos.com` is currently live on the old host. Before repointing:

1. Deploy this app first to **`imgproxy-staging.survos.com`** — a plain,
   throwaway name, not `imgproxy-pro.survos.com` (no reason to advertise the
   licensing tier in a public repo's docs) and not a reused/opaque name.
   `images.survos.com` was considered and rejected: it's the old free-tier
   imgproxy (v3), no longer used, and now a *live but broken* Cloudflare-proxied
   record (`curl -I https://images.survos.com/` → `520`). Confirmed dead —
   a candidate for decommissioning (drop the DNS record) as a follow-up, but
   out of scope for this migration.
2. Run the full curl verification suite from the 2026-07-09 incident against
   the staging URL (direct signed URLs, the `curl --resolve` bypass trick, a
   few real production image URLs from zm/md) before touching the real domain.
3. Confirm `imgproxy.survos.com`'s current Cloudflare record is **proxied
   (orange-cloud)** with SSL mode **Full** or **Full (strict)** — see the
   Cloudflare section below — and keep that same mode when repointing the A
   record to the new host's IP. Unlike `chat.survos.com` (DNS-only, per
   `mattermost/README.md`), this hostname is *not* the grey-cloud pattern —
   don't assume it is.
4. Only after (2) passes and (3) is confirmed, repoint the existing
   `imgproxy.survos.com` A record to the new host, decommission the old
   nginx/container setup, and tear down the staging DNS record.

## Cloudflare

`imgproxy.survos.com` sits behind Cloudflare as a real proxy, not just a DNS
host — verified directly (`curl -I https://imgproxy.survos.com/health`
returns `server: cloudflare`, a `cf-ray` id, and `cf-cache-status: MISS`).
This is the opposite of `chat.survos.com` in `mattermost/README.md`, which is
deliberately DNS-only to dodge a Flexible-SSL redirect loop — **don't assume
that pattern carries over here**, it doesn't.

- **Proxied (orange-cloud), SSL mode Full or Full (strict).** The origin
  vhost only listens on `443 ssl` (with a real Let's Encrypt cert) and
  redirects `:80` to `:443` — there's no plain-HTTP path for Cloudflare to
  reach the origin over, which rules out Flexible mode. Cloudflare must be
  connecting to origin over HTTPS using that cert, meaning genuine end-to-end
  TLS, not just edge-terminated. Confirm this SSL mode is preserved on cutover
  to the new host (same cert setup via `dokku letsencrypt`, same "only listen
  on 443" shape).
- **`cf-cache-status` is active and meaningful here** — unlike the missing
  `cf-cache-status` header observed on the stuck 502 during the 2026-07-09
  incident (which was nginx serving a stale cached error, never reaching
  Cloudflare's cache logic at all in a way that set the header). A real
  Cloudflare edge cache is in play for whatever this zone's default cache
  rules consider cacheable — worth checking Cloudflare's cache rules for this
  hostname specifically before assuming responses are always live from
  origin.
- **No WAF/rate-limiting rules exist on this zone** (confirmed during the
  2026-07-09 incident — checked Security Events, WAF custom rules, and Rate
  Limiting Rules; all empty). Whatever protection against abusive/bot traffic
  exists has to come from this app's own config (nginx `limit_req`, imgproxy's
  own limits) or Cloudflare's zone-wide, non-rule-based settings (Bot Fight
  Mode / the "Disallow AI Bots" toggle — currently enabled at the zone level,
  applies regardless of proxied/DNS-only status for this specific record).
- **Because this record is already proxied**, `real_ip_header`/`set_real_ip_from`
  (see Known follow-ups below) is directly relevant, not hypothetical — if any
  IP-based rate limiting (`limit_req`, currently absent from this repo's
  nginx config) gets added back, it needs Cloudflare's real client IP restored
  first, or it'll rate-limit the whole site's combined proxied traffic as one
  client. This exact gap contributed to how confusing the 2026-07-09 incident
  was to diagnose, even though it turned out not to be the actual root cause.

## nginx tuning (`nginx.conf.d/imgproxy.conf`)

Dokku supports per-app additive nginx config via `nginx.conf.d/*.conf` files
checked into the repo root, included into the generated vhost — this is
**not** a full vhost replacement; Dokku still owns TLS termination and the
`proxy_pass`/upstream wiring. `nginx.conf.d/imgproxy.conf` ports the tuning
from the hand-maintained vhost this replaces: response buffering sized for
image payloads, timeouts, security headers, and exposing imgproxy's own
`X-Result-Cache` header as `X-Cache-Status`.

**Validate after first deploy** — run `dokku nginx:show-config imgproxy` and
confirm the directives landed in the context you'd expect (Dokku versions
differ on whether app-supplied config lands at server- or location-level; the
`if ($request_method ...)` block specifically needs a `location` context to be
legal nginx — check that one first).

**Deliberately absent: any `proxy_cache*` directive.** That's not an
oversight — it's the fix for a real outage. On 2026-07-09,
`proxy_cache_valid any 0s;` combined with `proxy_cache_use_stale error timeout
...` on the old vhost caused nginx to cache a single transient 502 and serve
it to *every* client indefinitely, regardless of IP, browser, or user-agent.
Full writeup: `showcase` memory `imgproxy-502-nginx-cache-incident.md`. imgproxy
Pro's own S3-backed result cache (`IMGPROXY_CACHE_USE`) replaces this layer
entirely — do not reintroduce an nginx-level cache on top of it.

## Known follow-ups (carried over from the old host, not yet done here)

- **`real_ip_header`/`set_real_ip_from`** — the old host's nginx had no
  Cloudflare real-IP restoration configured at all, meaning any IP-based rate
  limiting there was keying off Cloudflare's shared edge IP rather than real
  visitor IPs. If rate limiting is added back here (it isn't, currently — no
  `limit_req` in this repo), it needs this configured first. Cloudflare's
  published ranges: `https://www.cloudflare.com/ips-v4` / `/ips-v6`.
- **`IMGPROXY_WORKERS` sizing** — the 2026-07 outage investigation found
  `Workers utilization: 44/16` (soft-limit overrun) on the old host under bot
  crawler load. Size this deliberately for this app rather than carrying over
  whatever the old host happened to have, and consider pairing with
  Cloudflare's "Disallow AI Bots" toggle (already enabled at the DNS/CDN layer)
  to reduce crawler load hitting origin at all.
- **Persistence/state**: this app is stateless other than the S3-backed result
  cache (no local volumes needed, unlike `mattermost`'s Postgres/plugin
  volumes) — confirm that holds once the real env is filled in.
