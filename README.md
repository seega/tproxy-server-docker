# tproxy-server-docker

Deploy [telegramdesktop/tproxy-server](https://github.com/telegramdesktop/tproxy-server)
with Docker Compose: a WEB-proxy relay, an official Telegram MTProxy backend,
Caddy automatic HTTPS, and an ordinary Nginx website.

**Unofficial community Docker packaging** — not affiliated with Telegram or
the upstream maintainers. The upstream WEB proxy is a proof-of-concept; not every
Telegram client supports this proxy type. The setup has been tested on a Linux VPS
with Telegram for iOS, using the regular App Store version (2 November 2026).
That is an individual deployment test, not a compatibility guarantee.

## How it works

```text
                         Internet :80/:443
                                |
                          Caddy (HTTPS)
                                |
                         tproxy-server
                          /          \
         normal HTTP requests        authenticated WEB sessions
                    |                          |
            Nginx public site          official MTProxy
                                               |
                                        Telegram network
```

Four containers share the MTProxy container's Docker **network namespace** because
the upstream relay requires the website and MTProxy backend to use numeric loopback
addresses. Only public TCP ports **80 and 443** are published. The internal
ports `2398`, `8888`, `8080`, `8081`, and `3000` remain unpublished.

## Requirements

- Linux x86_64 host with Docker Engine, Docker Compose v2, Git, and coreutils.
- One public IPv4 address reachable on TCP ports 80 and 443.
- A lowercase ASCII DNS hostname, such as `proxy.example.com`, whose **A** record
  points at that IPv4. Do not put an HTTP CDN/proxy in front of the initial setup.
- Available ports 80 and 443 on the host, plus outbound connectivity to Telegram
  and to the HTTPS endpoints used during installation.
- The account running `setup.sh` must have Docker permissions; membership in the
  `docker` group is effectively root-level access.

Do **not** publish the internal ports at your provider firewall either. Do not
set an `AAAA` record unless your server has working public IPv6 and you have
validated the deployment for it.

## Quick start

Clone this repository onto the VPS and run:

```bash
git clone https://github.com/seega/tproxy-server-docker.git
cd tproxy-server-docker
chmod +x setup.sh
./setup.sh proxy.example.com 203.0.113.10
```

Replace the example domain and public IPv4 with your own. The addresses
above are examples. **No email address is required.** Caddy obtains and renews
its TLS certificate automatically. The installer fetches pinned upstream source
code, generates credentials locally, and builds the four services.

`setup.sh` prints a secret and a WEB-proxy link; keep the secret private. Clients
can also be configured by entering the hostname and secret manually. The
`webproxy` URI is not handled by every Telegram client or `t.me` entry point.

If your account cannot access `/var/run/docker.sock`, give it Docker permissions
or use the following **after the first setup attempt has already created**
`.env` and `private/` (do not re-run `setup.sh` and rotate secrets):

```bash
sudo docker compose up -d --build
```

## Verification

```bash
docker compose ps
docker compose logs --tail=100 mtproxy tproxy nginx caddy
curl -I https://proxy.example.com/
docker compose exec -T tproxy wget -qO- http://127.0.0.1:8081/readyz
```

A working relay returns `ready` and the service appears as `healthy`.
Check that the public site returns a normal website response, that the TLS
certificate is valid, and that a WEB-compatible Telegram client can send and
receive actual traffic. A working website and `/readyz` alone do not prove that
Telegram's middle-end is connected.

```bash
# No repeated "Disconnected from RPC Middle-End" should appear:
docker compose logs --since=5m mtproxy | grep 'Disconnected from RPC Middle-End'
```

If middle-end connections repeatedly drop, verify `PUBLIC_IPV4` in `.env` and
Docker NAT. Official MTProxy is launched with `--nat-info` using the current
container IPv4 and the configured public IPv4.

If the relay shows `unhealthy`, inspect the MTProxy logs. The MTProxy process
needs at least 65,552 open-file descriptors with the included settings; this
Compose file sets `ulimits.nofile` to **1,048,576**. Failure without the limit
looks like `fatal: cannot raise open file limit to 65552`.

## Updating an existing installation (Git clone)

For a server originally installed with `git clone` and initialized once with
`./setup.sh`, update the running deployment **without regenerating credentials**:

```bash
cd ~/tproxy-server-docker

# Review local changes before pulling; don't discard your own modifications.
git status --short
git pull --ff-only

# Rebuild the local images using the latest base images, then apply changes.
docker compose build --pull
docker compose up -d --no-build

# Confirm all services are running and the relay is ready.
docker compose ps
docker compose exec -T tproxy wget -qO- http://127.0.0.1:8081/readyz
```

The readiness request should print `ready`. Also check the public HTTPS site
and send a message through your Telegram WEB proxy. Updating/recreating the
containers can briefly disconnect existing proxy sessions.

If you normally manage Docker with `sudo`, prefix **only** the
`docker compose` commands with `sudo`; run `git pull` as the repository
owner. If `git pull --ff-only` refuses because you edited tracked files,
review and resolve those changes first instead of forcing or deleting them.

**Your existing MTProxy secret and proxy link stay unchanged.** `git pull`
does not replace the ignored `.env` or `private/` directory, and Compose
mounts these existing files into the containers. The persistent signing key is
`private/token.key`; Caddy certificates and MTProxy routing data are retained
in the `caddy-data` and `mtproxy-data` named volumes. Back up credentials
securely before major changes.

**Do not run `setup.sh` again**, delete `.env` or `private/`, use
`git clean -fdx`, or execute `docker compose down -v` during an update.
Those operations may delete credentials, source state or named volumes.
A normal `docker compose down` without `-v` preserves named volumes.

To also update the separately pulled Caddy and Nginx images, run
`docker compose pull caddy nginx` before `docker compose up -d --no-build`.
This updates those services too and may involve additional restarts.

**Note:** `upstream/` contains the pinned `tproxy-server` source checkout
from the original installation. Updating this packaging repository does not
automatically change that pinned upstream checkout.

## Operations

```bash
docker compose logs -f --tail=100
# Edit files inside site/ to change the public website:
docker compose restart nginx
# After editing private/config.json or private/profiles.json:
docker compose restart tproxy
# Re-create with the existing secrets and volumes:
docker compose up -d --build --force-recreate
# Stop without deleting secrets or certificates:
docker compose down
```

The official Telegram backend config is fetched during startup, validated, cached
in the `mtproxy-data` named volume, and checked again daily. Its child process is
restarted when that config changes. The Caddy certificates are persisted in the
`caddy-data` volume.

## Security and backups

**Never commit** `.env`, `private/`, `upstream/`, `private/token.key`,
`private/profiles.json`, your real proxy secret, or a live data-volume export.
These generated paths are ignored by Git, but always inspect `git status` and
`git diff --cached` before pushing. A public repo is **not** the right place to
store your running server's credentials.

Back up `private/` (including the persistent 32-byte signing key) and the Caddy
and MTProxy Docker volumes securely. Do not run `docker compose down -v` unless
you intentionally want to discard named-volume state. Do not serve untrusted
JavaScript or install a service worker on the proxy's public origin; the normal
website and the authenticated bridge share the same origin.

The default page is just a generic Nginx welcome-page lookalike; it does not
guarantee that the service is undetectable. This is an experimental server, not
an assurance of privacy or censorship resistance.

## Sources and license

- [tproxy-server](https://github.com/telegramdesktop/tproxy-server)
  — pinned commit `c8adb8b7c6b7fc46c12ae3acb68be9070c26a8e8`
  (29 September 2026).
- [Official Telegram MTProxy](https://github.com/TelegramMessenger/MTProxy)
  — pinned commit `f36d8af769ffaeac36978d38c2c0f6d1104c2137`.
- [Upstream deployment instructions](https://github.com/telegramdesktop/tproxy-server/blob/master/README.md)
  and [public website requirements](https://github.com/telegramdesktop/tproxy-server/blob/master/PUBLIC_SITE.md).

This repository contains Docker packaging, scripts and a basic public HTML site.
The third-party sources are fetched during installation/build; their own
copyright and license terms continue to apply. The original Docker packaging
in this repository is MIT-licensed; see [LICENSE](LICENSE).
