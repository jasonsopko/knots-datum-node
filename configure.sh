#!/bin/bash
# SPDX-License-Identifier: MIT
# Change the node, payout address, pool and names of an installed
# knots-datum-node.
# Asks each question with the current value as the default, saves the answers,
# and restarts the gateway so they take effect.
#
# Usage, as the user that runs the node:
#   ~/knots-datum-node/configure
#
# Settings can also be given as flags: --address <address> --mode pool|solo
# [--tag <your name>] [--primary-tag <name>]
# [--pool-host <host[:port]> --pool-pubkey <hex>]
# [--node <host[:port]> --rpc-user <user>, password in NODE_RPC_PASSWORD]
# [--dashboard network|local] [--shared yes|no] [--no-prompt]
# --show-password prints the dashboard address and password, and exits.
set -euo pipefail
SRC_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
. "$SRC_DIR/lib.sh"

NO_PROMPT=0 SHOW_PASSWORD=0
while [ $# -gt 0 ]; do
	if parse_setting_flag "$@"; then shift "$SHIFT"; continue; fi
	case "$1" in
		--no-prompt) NO_PROMPT=1; shift ;;
		--show-password) SHOW_PASSWORD=1; shift ;;
		-h|--help) sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) die "unknown option $1 (see configure --help)" ;;
	esac
done

[ "$(id -u)" != 0 ] || die "do not run this as root. Run it as the user that runs the node."
require_python
load_saved_settings
[ $HAVE_SAVED = 1 ] && [ -n "$S_RPC_PASS" ] || die "no installed node found in $BASE. Run ./install.sh first."
if [ $SHOW_PASSWORD = 1 ]; then
	DASH_OPEN=$S_DASH_OPEN
	echo "Dashboard: $(dashboard_url)"
	echo "Username:  admin"
	echo "Password:  $S_API_PASS"
	exit 0
fi

settle_settings
[ "$NODE" = existing ] || [ "$S_NODE" = new ] || die "installing a new node here needs the download and build: run ./install.sh from the installer folder instead"
echo
echo "New settings:"
show_settings
if [ -t 0 ] && [ -t 1 ] && [ $NO_PROMPT = 0 ]; then
	echo
	read -r -p "Save these? [Y/n]: " ok || ok=n
	case "${ok,,}" in ""|y|yes) ;; *) echo "Nothing changed."; exit 0 ;; esac
fi

if [ "$NODE" = existing ] && [ -f "$UNITS/$NODE_UNIT" ]; then
	echo "Stopping the node this installed earlier; its data stays in $DATA."
	user_systemctl disable --now "$NODE_UNIT" 2>/dev/null || true
	rm -f "$UNITS/$NODE_UNIT" "$CONF/bitcoin.conf"
fi
(umask 077; render_gateway_json "$RPC_PASS" "$DASH_PASS" > "$CONF/datum_gateway.json.new")
mv "$CONF/datum_gateway.json.new" "$CONF/datum_gateway.json"
render_gateway_unit > "$UNITS/$GW_UNIT"
render_status_script > "$BASE/status"
user_systemctl daemon-reload
if user_systemctl is-active --quiet "$GW_UNIT"; then
	user_systemctl restart "$GW_UNIT"
	echo "Saved. The gateway restarted with the new settings."
else
	echo "Saved. They take effect when the gateway next starts."
fi
echo
echo "Miners connect with:"
miner_login_help
echo
dashboard_help
FW=$(firewall_commands | grep -E -- ":?$API_PORT|--reload" || true)
if [ "$DASH_OPEN" = network ] && [ -n "$LAN_CIDR" ] && [ -n "$FW" ]; then
	echo
	echo "If this computer has a firewall turned on, an administrator also needs to run:"
	echo "$FW" | sed 's/^/    /'
fi

