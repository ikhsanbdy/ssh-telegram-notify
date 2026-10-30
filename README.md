# ssh-telegram-notify

Send a Telegram notification whenever someone logs in to an Ubuntu server over
SSH, including `scp`, `sftp`, `rsync`, and `ssh host command`.

Example message:

```
🔐 SSH Login
Server : web-01 (10.0.0.12)
User   : root
From IP: 203.0.113.9
Time   : 2026-10-30 14:57:12 WIB
```

## How it works

The script is called by `pam_exec` from `/etc/pam.d/sshd`. PAM opens one
session for every SSH connection, whatever it is used for, so every kind of
access is caught. Users cannot turn it off from their own `.bashrc`.

- The message is sent in the background with a 10-second timeout, so slow DNS
  or an unreachable Telegram API never delays the login.
- The module is added as `optional`, so logins still work if the script fails.
- Failed sends are logged to syslog: `journalctl -t ssh-telegram-notify`.

## Security notes

The script runs as **root** on every login, so it is hardened accordingly:

- The PAM line is inserted **before** `pam_env.so`. Ubuntu's sshd PAM config
  reads `~/.pam_environment` (`user_readenv=1`), which any user, including
  sftp-only accounts, can write. Anything placed after `pam_env.so` would run
  as root with user-controlled variables such as `LD_PRELOAD`, `BASH_ENV`, or
  `PATH`. Do not move the line below `pam_env.so`.
- It only runs on login (`type=open_session`). There is no logout notification
  on purpose: by logout time the user's variables are already loaded, wherever
  the line sits.
- The script uses `#!/bin/bash -p` and a fixed `PATH`, and only reads the config
  at a fixed path.
- The config is sourced as root, so the script refuses it unless it is owned by
  root and not writable by group or others.
- The bot token is never passed on the command line, so it does not show up in
  `ps`.

To check the order on your server:

```bash
grep -n -e pam_exec -e pam_env /etc/pam.d/sshd
```

The `pam_exec` line must have a lower line number than every `pam_env` line.

Limitation: the message cannot say which kind of access it was (shell, scp, or
sftp), because the PAM session opens before the client asks for a shell or the
sftp subsystem. Multiplexed connections (`ControlMaster`) trigger only one
notification.

## 1. Set up the bot

1. Message [@BotFather](https://t.me/BotFather), send `/newbot`, and save the **token**.
2. Send any message to your bot (or add the bot to a group and send a message there).
3. Open `https://api.telegram.org/bot<TOKEN>/getUpdates` and copy the value of
   `"chat":{"id": ...}`. That is your **CHAT_ID** (negative for groups).

## 2. Install on the server

```bash
scp -r ssh-telegram-notify user@server:/tmp/
ssh user@server
cd /tmp/ssh-telegram-notify
sudo ./install.sh
```

If SSH runs on a non-default port, use `-P <port>` for `scp` and `-p <port>`
for `ssh`. The port makes no difference to the notifications.

The installer will:
- copy the script to `/usr/local/bin/ssh-telegram-notify.sh`
- create the config `/etc/ssh-telegram-notify.conf` (chmod 600, owned by root)
- back up `/etc/pam.d/sshd` and insert this line before the first `pam_env.so`
  line: `session optional pam_exec.so quiet type=open_session /usr/local/bin/ssh-telegram-notify.sh`
- send a test message and report Telegram's error if it fails

Re-running the installer is safe. It also moves the PAM line from older
versions, which appended it at the end of the file, to the correct position.

To install without prompts (for example from Ansible or cloud-init), put a
valid `/etc/ssh-telegram-notify.conf` in place first. The installer will use it.

There is no need to restart sshd, because the PAM config is read on every login.
Keep an existing SSH session open until the test message arrives, just in case.

## 3. Test

Open a new SSH connection, or try `sftp user@server`, and check that a message
arrives. To test manually: `sudo /usr/local/bin/ssh-telegram-notify.sh --test`

## Configuration

Edit `/etc/ssh-telegram-notify.conf`:

| Variable        | Purpose                                           |
|-----------------|---------------------------------------------------|
| `BOT_TOKEN`     | Bot token                                         |
| `CHAT_ID`       | Target chat, group, or channel                    |
| `IGNORE_IPS`    | Space-separated IPs that are not notified (exact) |
| `IGNORE_USERS`  | Space-separated users that are not notified       |

## Uninstall

```bash
sudo ./install.sh --uninstall
sudo rm /etc/ssh-telegram-notify.conf   # optional
```

## License

[MIT](LICENSE) © 2026 Ikhsan Budiyanto
