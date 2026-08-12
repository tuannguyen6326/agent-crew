#!/usr/bin/env bash
# ac-notify.sh - best-effort captain notification (the wedge-alarm surface).
#
# Usage: ac-notify.sh <title> <message...>
#
# Channel comes from config/wedge-alarm:
#   off            no notification
#   auto (default) herdr when it is the configured backend and installed,
#                  else macOS osascript, else a terminal bell
#   herdr          herdr notification show <title> --body <message>
#                  (silent; position applies only to in-herdr toasts)
#   osascript      macOS notification center
#   bell           terminal bell on stderr
#   command:<cmd>  run <cmd> via sh -c with AC_NOTIFY_TITLE/AC_NOTIFY_MESSAGE
#
# Notifications are advisory: this script never fails (exit 0 always) and
# never blocks the watcher on a broken channel.

set -uo pipefail
. "$(dirname "$0")/ac-lib.sh"

title="${1:-agent-crew}"
shift || true
message="${*:-}"

channel="$(ac_config_read wedge-alarm auto)"

deliver_herdr() { herdr notification show "$title" --body "$message" --sound none --position top-right >/dev/null 2>&1; }
deliver_osascript() {
  osascript -e "display notification \"${message//\"/\\\"}\" with title \"${title//\"/\\\"}\"" >/dev/null 2>&1
}
deliver_bell() { printf '\a%s: %s\n' "$title" "$message" >&2; }

case "$channel" in
  off) : ;;
  herdr) deliver_herdr || deliver_bell ;;
  osascript) deliver_osascript || deliver_bell ;;
  bell) deliver_bell ;;
  command:*)
    AC_NOTIFY_TITLE="$title" AC_NOTIFY_MESSAGE="$message" \
      sh -c "${channel#command:}" >/dev/null 2>&1 || deliver_bell ;;
  *) # auto (and any unknown value degrades to auto)
    if [ "$(ac_config_read backend herdr)" = "herdr" ] && command -v herdr >/dev/null 2>&1; then
      deliver_herdr || deliver_bell
    elif command -v osascript >/dev/null 2>&1; then
      deliver_osascript || deliver_bell
    else
      deliver_bell
    fi
    ;;
esac
exit 0
