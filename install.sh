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

# Print PAM_FILE without our entries, including the ones older versions
# appended at the end of the file.
pam_without_entry() {
  sed -e '\|^# ssh-telegram-notify|d' \
      -e '\|^# Telegram notification on SSH login$|d' \
      -e "\|pam_exec\.so .*${BIN}|d" "$PAM_FILE"
}

# Write new PAM_FILE content from stdin, with a backup, only if it changed.
# `cat >` keeps the original owner and mode.
pam_write() {
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  if ! cmp -s "$tmp" "$PAM_FILE"; then
    cp -a "$PAM_FILE" "${PAM_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    cat "$tmp" > "$PAM_FILE"
    echo "Updated $PAM_FILE (backup created)."
  fi
  rm -f "$tmp"
}

if [ "${1:-}" = "--uninstall" ]; then
  pam_without_entry | pam_write
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
pam_without_entry |
  awk -v marker="$PAM_MARKER" -v line="$PAM_LINE" '
    !done && /^[[:space:]]*session[[:space:]].*pam_env\.so/ { print marker; print line; done = 1 }
    { print }
    END { if (!done) { print ""; print marker; print line } }
  ' | pam_write

if grep -Eq '^[[:space:]]*auth[[:space:]].*pam_env\.so' "$PAM_FILE" /etc/pam.d/common-auth 2>/dev/null; then
  echo "WARNING: pam_env.so is used in the auth stack; user variables may reach" >&2
  echo "         the notify script. Review $PAM_FILE before relying on it." >&2
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
