#!/bin/bash
# SPDX-License-Identifier: MIT
# Change the payout address, pool and names of an installed knots-datum-node.
# Asks each question with the current value as the default, saves the answers,
# and restarts the gateway so they take effect.
#
# Usage, as the user that runs the node:
#   ~/knots-datum-node/configure
#
# Settings can also be given as flags: --address <address> --mode pool|solo
# [--tag <your name>] [--primary-tag <name>]
# [--pool-host <host[:port]> --pool-pubkey <hex>] [--no-prompt]
set -euo pipefail
SRC_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
. "$SRC_DIR/lib.sh"

NO_PROMPT=0
while [ $# -gt 0 ]; do
	if parse_setting_flag "$@"; then shift "$SHIFT"; continue; fi
	case "$1" in
		--no-prompt) NO_PROMPT=1; shift ;;
		-h|--help) sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) die "unknown option $1 (see configure --help)" ;;
	esac
done

[ "$(id -u)" != 0 ] || die "do not run this as root. Run it as the user that runs the node."
require_python
load_saved_settings
[ $HAVE_SAVED = 1 ] && [ -n "$S_RPC_PASS" ] || die "no installed node found in $BASE. Run ./install.sh first."

settle_settings
echo
echo "New settings:"
show_settings
if [ -t 0 ] && [ -t 1 ] && [ $NO_PROMPT = 0 ]; then
	echo
	read -r -p "Save these? [Y/n]: " ok || ok=n
	case "${ok,,}" in ""|y|yes) ;; *) echo "Nothing changed."; exit 0 ;; esac
fi

(umask 077; render_gateway_json "$S_RPC_PASS" "$S_API_PASS" > "$CONF/datum_gateway.json.new")
mv "$CONF/datum_gateway.json.new" "$CONF/datum_gateway.json"
if user_systemctl is-active --quiet "$GW_UNIT"; then
	user_systemctl restart "$GW_UNIT"
	echo "Saved. The gateway restarted with the new settings."
else
	echo "Saved. They take effect when the gateway next starts."
fi
