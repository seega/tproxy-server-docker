#!/usr/bin/env bash
set -Eeuo pipefail

DATA_DIR=/var/lib/mtproxy
PROFILE=/run/tproxy/profiles.json
mkdir -p "$DATA_DIR"

if [[ ! "${PUBLIC_IPV4:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo >&2 'PUBLIC_IPV4 must be an IPv4 address'
  exit 1
fi
if [[ ! -r "$PROFILE" ]]; then
  echo >&2 "Cannot read $PROFILE"
  exit 1
fi
SECRET="$(jq -r '.profiles[0].secret // empty' "$PROFILE")"
if [[ ! "$SECRET" =~ ^[0-9a-f]{32}$ ]]; then
  echo >&2 'The first profile must have a 16-byte hex secret'
  exit 1
fi
LOCAL_IP="$(ip -4 route get 1.1.1.1 | sed -nE 's/.* src ([0-9.]+).*/\1/p' | head -n1)"
if [[ -z "$LOCAL_IP" ]]; then
  echo >&2 'Cannot discover local Docker IPv4 for --nat-info'
  exit 1
fi

echo "MTProxy private address: $LOCAL_IP / public NAT address: $PUBLIC_IPV4"

# Atomic downloads with validation. Return 10 when files have changed.
refresh_files() {
  local one two changed=0
  one="$(mktemp "$DATA_DIR/.secret.XXXXXX")"
  two="$(mktemp "$DATA_DIR/.routing.XXXXXX")"
  if ! curl --fail --silent --show-error --location --max-time 30 \
       --proto '=https' --proto-redir '=https' --tlsv1.2 \
       -o "$one" https://core.telegram.org/getProxySecret \
    || ! curl --fail --silent --show-error --location --max-time 30 \
       --proto '=https' --proto-redir '=https' --tlsv1.2 \
       -o "$two" https://core.telegram.org/getProxyConfig; then
    rm -f "$one" "$two"
    return 1
  fi
  if [[ $(wc -c < "$one") -ne 128 ]] \
     || [[ $(wc -c < "$two") -lt 100 ]] \
     || ! grep -q '^default ' "$two" \
     || ! grep -q '^proxy_for ' "$two"; then
    echo >&2 'Downloaded Telegram proxy config failed validation'
    rm -f "$one" "$two"
    return 1
  fi
  chmod 0644 "$one" "$two"
  if ! cmp -s "$one" "$DATA_DIR/proxy-secret"; then
    mv -f "$one" "$DATA_DIR/proxy-secret"
    changed=1
  else
    rm -f "$one"
  fi
  if ! cmp -s "$two" "$DATA_DIR/proxy-multi.conf"; then
    mv -f "$two" "$DATA_DIR/proxy-multi.conf"
    changed=1
  else
    rm -f "$two"
  fi
  if [[ $changed -eq 1 ]]; then return 10; fi
  return 0
}

if refresh_files; then
  :
else
  status=$?
  if [[ "$status" -ne 10 ]] && { [[ ! -s "$DATA_DIR/proxy-secret" ]] || [[ ! -s "$DATA_DIR/proxy-multi.conf" ]]; }; then
    echo >&2 'No valid cached Telegram config; cannot start'
    exit 1
  fi
  if [[ "$status" -ne 10 ]]; then echo >&2 'Using cached Telegram config'; fi
fi

parent_pid="$BASHPID"
mt_pid=''
stopping=0
restarting=0
on_terminate() {
  stopping=1
  [[ -z "$mt_pid" ]] || kill -TERM "$mt_pid" 2>/dev/null || true
}
on_reload() {
  restarting=1
  [[ -z "$mt_pid" ]] || kill -TERM "$mt_pid" 2>/dev/null || true
}
trap on_terminate INT TERM
trap on_reload USR1

# Upstream's systemd installer refreshes routes daily and restarts MTProxy
# on change. Restart only its child here: keep the shared Docker namespace.
(
  while sleep 86400; do
    if refresh_files; then
      :
    else
      status=$?
      if [[ "$status" -eq 10 ]]; then
        echo 'Telegram routing updated; reloading MTProxy'
        kill -USR1 "$parent_pid" 2>/dev/null || true
      else
        echo >&2 'Telegram routing refresh failed; retaining cached files'
      fi
    fi
  done
) &
refresh_pid=$!

while [[ $stopping -eq 0 ]]; do
  /usr/local/bin/mtproto-proxy \
    -u nobody -p 8888 -H 2398 -S "$SECRET" \
    --nat-info "$LOCAL_IP:$PUBLIC_IPV4" \
    --aes-pwd "$DATA_DIR/proxy-secret" "$DATA_DIR/proxy-multi.conf" \
    -M 1 -C 4096 &
  mt_pid=$!
  wait "$mt_pid" || true
  # A signal interrupts Bash wait even while MTProxy is still finishing.
  wait "$mt_pid" 2>/dev/null || true
  mt_pid=''
  if [[ $stopping -eq 1 ]]; then break; fi
  if [[ $restarting -eq 1 ]]; then
    restarting=0
    continue
  fi
  echo >&2 'MTProxy exited unexpectedly, restarting in 3 seconds'
  sleep 3
done
kill "$refresh_pid" 2>/dev/null || true
wait "$refresh_pid" 2>/dev/null || true
