#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
cd "$(dirname "$0")"

domain="${1:-}"
public_ip="${2:-}"
if [[ $# -ne 2 || -z "$domain" || -z "$public_ip" ]]; then
  echo "Usage: $0 proxy.example.com PUBLIC_IPV4" >&2
  exit 2
fi
if ! [[ "$domain" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ && "$domain" == *.* ]]; then
  echo >&2 'Use a lowercase ASCII hostname, without https:// or a trailing dot'
  exit 2
fi
if ! [[ "$public_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo >&2 'Use an IPv4 address'; exit 2
fi
IFS=. read -r a b c d <<< "$public_ip"
for octet in "$a" "$b" "$c" "$d"; do
  if (( 10#$octet > 255 )); then echo >&2 'Invalid IPv4 address'; exit 2; fi
done
for command in git docker od head tr; do
  command -v "$command" >/dev/null || { echo >&2 "Missing command: $command"; exit 1; }
done
docker compose version >/dev/null || { echo >&2 'Docker Compose v2 is required'; exit 1; }
if [[ -e .env || -e private/profiles.json || -e private/token.key ]]; then
  echo >&2 'Deployment already initialized. Refusing to overwrite secrets.'
  echo >&2 'Use: docker compose up -d --build'
  exit 1
fi

# Pin the Go proof-of-concept to the revision inspected for this package.
repo_commit=c8adb8b7c6b7fc46c12ae3acb68be9070c26a8e8
if [[ ! -d upstream/.git ]]; then
  mkdir -p upstream
  git -C upstream init -q
  git -C upstream remote add origin https://github.com/telegramdesktop/tproxy-server.git
  git -C upstream fetch --depth=1 origin "$repo_commit"
  git -C upstream checkout --quiet --detach FETCH_HEAD
fi
if [[ "$(git -C upstream rev-parse HEAD)" != "$repo_commit" ]]; then
  echo >&2 'Upstream checkout differs from the pinned commit. Aborting.'
  exit 1
fi

mkdir -p private
chmod 0700 private
secret="$(head -c 16 /dev/urandom | od -An -v -tx1 | tr -d '[:space:]')"
head -c 32 /dev/urandom > private/token.key
chmod 0400 private/token.key

cat > private/config.json <<CONFIG
{
  "public_hostname": "$domain",
  "base_path": "",
  "listen": "127.0.0.1:8080",
  "admin_listen": "127.0.0.1:8081",
  "public_upstream": "http://127.0.0.1:3000",
  "token_key_file": "/run/tproxy/token.key",
  "profiles_file": "/run/tproxy/profiles.json",
  "static_routes": "exact",
  "enable_pprof": false
}
CONFIG

cat > private/profiles.json <<PROFILES
{
  "profiles": [
    {
      "name": "default",
      "secret": "$secret",
      "backend": "127.0.0.1:2398",
      "carrier_mode": "https"
    }
  ]
}
PROFILES
chmod 0400 private/config.json private/profiles.json

cat > .env <<ENV
TPROXY_HOSTNAME=$domain
PUBLIC_IPV4=$public_ip
HOST_UID=$(id -u)
HOST_GID=$(id -g)
ENV
chmod 0600 .env

printf '\n' >&2
printf 'Source revision: %s\n' "$repo_commit"
printf 'Proxy server:   %s\n' "$domain"
printf 'Proxy secret:   %s\n' "$secret"
printf 'Proxy link:     https://t.me/webproxy?server=%s&secret=%s\n' "$domain" "$secret"
printf '\nRemember: this requires a WEB-proxy-capable Telegram client.\n\n'

docker compose config --quiet
docker compose up -d --build

echo
printf 'Website: https://%s/\n' "$domain"
echo 'Diagnostics: docker compose ps && docker compose logs --tail=100 -f'
