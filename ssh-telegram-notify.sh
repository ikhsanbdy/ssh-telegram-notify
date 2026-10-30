#!/bin/bash -p
# Send a Telegram notification on SSH login.
# Called by pam_exec (type=open_session) from /etc/pam.d/sshd, which sets
# PAM_USER and PAM_RHOST. A PAM session is opened once per SSH connection,
# so shell, scp, sftp, rsync, and `ssh host cmd` are all caught.
#
# Security: this runs as root. The PAM line must sit BEFORE pam_env.so in
# /etc/pam.d/sshd, otherwise users can inject variables such as LD_PRELOAD,
# BASH_ENV, or PATH through ~/.pam_environment. install.sh handles this.
# For the same reason there is no logout notification: by close_session the
# user's variables are already in the PAM environment.
#
# Manual test: sudo /usr/local/bin/ssh-telegram-notify.sh --test

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CONFIG_FILE=/etc/ssh-telegram-notify.conf

MODE=pam
[ "$1" = "--test" ] && MODE=test

# In test mode errors go to the terminal; during login they go to syslog
# and the login continues.
fail() {
  if [ "$MODE" = test ]; then
    echo "ERROR: $*" >&2
    exit 1
  fi
  logger -t ssh-telegram-notify "$*"
  exit 0
}

# The config is sourced as root, so refuse one that others could modify.
[ -f "$CONFIG_FILE" ] || fail "$CONFIG_FILE not found"
[ -O "$CONFIG_FILE" ] || fail "$CONFIG_FILE must be owned by root"
[ -z "$(find "$CONFIG_FILE" \( -perm -020 -o -perm -002 \))" ] ||
  fail "$CONFIG_FILE must not be group/world writable"
# shellcheck source=/dev/null
. "$CONFIG_FILE"
[ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ] || fail "BOT_TOKEN or CHAT_ID is empty"
# The token goes into a curl config line below; reject anything that could
# break out of its quotes and add curl options.
[[ "$BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || fail "BOT_TOKEN has an invalid format"

if [ "$MODE" = test ]; then
  TITLE="✅ <b>Test Notification</b>"
  PAM_USER="${SUDO_USER:-$(id -un)}"
  PAM_RHOST="manual test"
else
  [ "$PAM_TYPE" = "open_session" ] || exit 0
  TITLE="🔐 <b>SSH Login</b>"

  # Skip IPs or users in the ignore lists (space-separated, no globbing).
  set -f
  for ip in $IGNORE_IPS; do
    [ "$PAM_RHOST" = "$ip" ] && exit 0
  done
  for u in $IGNORE_USERS; do
    [ "$PAM_USER" = "$u" ] && exit 0
  done
fi

# Escape text for Telegram's HTML parse mode. Unescaped < or & would make
# Telegram reject the whole message.
html() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Source address of the default route: the server's main IP, even when
# other interfaces (docker0, VPNs) exist. No packet is sent.
server_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null |
    awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }'
}

# Prints the response body, a newline, then the HTTP status code.
send() {
  local name ip now msg
  name="${SERVER_NAME:-$(hostname -s 2>/dev/null || hostname)}"
  ip="$(server_ip)"
  # An empty TZ means UTC, so only set it for a time zone that exists.
  if [ -n "$TIMEZONE" ] && [ -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
    now="$(TZ="$TIMEZONE" date '+%d %b %Y, %H:%M:%S %Z')"
  else
    now="$(date '+%d %b %Y, %H:%M:%S %Z')"
  fi

  msg="${TITLE} · $(html "$name")

👤 <b>User:</b> <code>$(html "${PAM_USER:-?}")</code>
🌐 <b>From:</b> <code>$(html "${PAM_RHOST:-?}")</code>${ip:+
🖥️ <b>Server IP:</b> <code>$(html "$ip")</code>}
🕒 <b>Time:</b> $(html "$now")"

  # The token is passed via stdin (curl -K -) so it doesn't show up in `ps`.
  # -q must come first: it stops curl from reading any .curlrc.
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$BOT_TOKEN" |
    curl -q -sS --max-time 10 -K - \
      --data-urlencode "chat_id=${CHAT_ID}" \
      --data-urlencode "text=${msg}" \
      -d "parse_mode=HTML" \
      -d "disable_web_page_preview=true" \
      -w '\n%{http_code}' 2>/dev/null
}

# Turns send() output into an error message; returns 0 on HTTP 200.
check() {
  local code="${1##*$'\n'}" body="${1%$'\n'*}" desc
  [ "$code" = "200" ] && return 0
  if [ "$code" = "000" ]; then
    echo "failed to send notification: cannot reach api.telegram.org (DNS, firewall, or timeout)"
    return 1
  fi
  desc="$(printf '%s' "$body" | sed -n 's/.*"description":"\([^"]*\)".*/\1/p')"
  echo "failed to send notification (HTTP ${code}: ${desc:-$body})"
  return 1
}

if [ "$MODE" = test ]; then
  err="$(check "$(send)")" || fail "$err"
  echo "Test message sent."
  exit 0
fi

# Runs in the background so a slow DNS or Telegram API never delays the login.
{
  err="$(check "$(send)")" || logger -t ssh-telegram-notify "$err"
} </dev/null >/dev/null 2>&1 &

exit 0
