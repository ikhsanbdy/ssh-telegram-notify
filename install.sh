#!/usr/bin/env bash
# Installer for Telegram SSH login notifications (Ubuntu/Debian).
#   sudo ./install.sh              -> install (safe to re-run; also upgrades)
#   sudo ./install.sh --uninstall  -> uninstall
set -euo pipefail

BIN=/usr/local/bin/ssh-telegram-notify.sh
CONF=/etc/ssh-telegram-notify.conf
PAM_FILE=/etc/pam.d/sshd
PAM_MARKER="# ssh-telegram-notify: must stay before pam_env.so (see README)"
PAM_LINE="session optional pam_exec.so quiet type=open_session ${BIN}"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "Please run with sudo." >&2; exit 1; }

# Print a PAM file without our entries, including the ones older versions
# appended at the end of the file.
pam_strip() {
  sed -e '\|^# ssh-telegram-notify|d' \
      -e '\|^# Telegram notification on SSH login$|d' \
      -e "\|pam_exec\.so .*${BIN}|d" "$1"
}

# Replace PAM_FILE with stdin, only if it changed, keeping a backup.
# A truncated /etc/pam.d/sshd would lock everyone out of SSH, so the new
# content must differ from the old one only in our entries, and it is
# moved into place atomically.
pam_write() {
  local tmp
  tmp="$(mktemp "${PAM_FILE}.new.XXXXXX")"
  cat > "$tmp"
  if cmp -s "$tmp" "$PAM_FILE"; then
    rm -f "$tmp"
    return 0
  fi
  if ! cmp -s <(pam_strip "$tmp") <(pam_strip "$PAM_FILE"); then
    rm -f "$tmp"
    echo "ERROR: refusing to write $PAM_FILE: unexpected changes outside our entry." >&2
    return 1
  fi
  chown --reference="$PAM_FILE" "$tmp"
  chmod --reference="$PAM_FILE" "$tmp"
  sync "$tmp"
  cp -a "$PAM_FILE" "${PAM_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  mv -f "$tmp" "$PAM_FILE"
  echo "Updated $PAM_FILE (backup created)."
}

if [ "${1:-}" = "--uninstall" ]; then
  pam_strip "$PAM_FILE" | pam_write
  rm -f "$BIN"
  echo "PAM line and script removed. Config $CONF was kept (delete it manually if needed)."
  exit 0
fi

command -v curl >/dev/null || apt-get install -y curl

install -o root -g root -m 755 "$SRC_DIR/ssh-telegram-notify.sh" "$BIN"

if [ ! -f "$CONF" ]; then
  read -rsp "BOT_TOKEN (hidden): " token; echo
  read -rp  "CHAT_ID          : " chat
  # Validate before writing: the config is sourced as root.
  [[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || { echo "Invalid BOT_TOKEN format." >&2; exit 1; }
  [[ "$chat" =~ ^(-?[0-9]+|@[A-Za-z0-9_]+)$ ]] || { echo "Invalid CHAT_ID format." >&2; exit 1; }
  install -o root -g root -m 600 "$SRC_DIR/ssh-telegram-notify.conf.example" "$CONF"
  sed -i "s|^BOT_TOKEN=.*|BOT_TOKEN=\"${token}\"|; s|^CHAT_ID=.*|CHAT_ID=\"${chat}\"|" "$CONF"
else
  echo "Config $CONF already exists, not overwriting."
fi
chown root:root "$CONF"
chmod 600 "$CONF"

# Insert our line right before the first pam_env.so session line, so users
# cannot inject variables (LD_PRELOAD, BASH_ENV, PATH) via ~/.pam_environment.
pam_strip "$PAM_FILE" |
  awk -v marker="$PAM_MARKER" -v line="$PAM_LINE" '
    !done && /^[[:space:]]*session[[:space:]].*pam_env\.so/ { print marker; print line; done = 1 }
    { print }
    END { if (!done) { print marker; print line } }
  ' | pam_write

# The ordering above only covers this file. A pam_env.so that reads user
# files in the sshd auth stack, or in any common-* file (common-session is
# included before our line), still runs before the notify script.
if grep -Eqs '^[[:space:]]*auth[[:space:]].*pam_env\.so.*user_readenv=1' "$PAM_FILE" ||
   grep -Eqs '^[^#]*pam_env\.so.*user_readenv=1' /etc/pam.d/common-*; then
  echo "WARNING: pam_env.so with user_readenv=1 runs before the notify script" >&2
  echo "         (sshd auth stack or /etc/pam.d/common-*). Users could inject" >&2
  echo "         variables into it as root. Remove user_readenv=1 there first." >&2
fi

if ! sshd -T 2>/dev/null | grep -qi '^usepam yes'; then
  echo "WARNING: UsePAM is not enabled in sshd_config; notifications will not work." >&2
fi

echo "PAM entry (must come before pam_env.so):"
grep -n -e 'pam_exec' -e 'pam_env' "$PAM_FILE" | sed 's/^/  /'

echo "Sending test message..."
if ! "$BIN" --test; then
  echo "Installed, but the test message failed. Fix $CONF, then run: sudo $BIN --test" >&2
  exit 1
fi
echo "Done."
