# SPDX-License-Identifier: MIT
# Shared by install.sh and configure.sh. Not meant to be run on its own.

KNOTS_VER=29.4.2.knots20260508
KNOTS_BASE=https://bitcoinknots.org/files/29.x/$KNOTS_VER
KNOTS_FPR=1A3E761F19D2CC7785C5502EA291A2C45D0C504A   # Luke Dashjr (Codesigning)
KNOTS_KEY_URL=https://raw.githubusercontent.com/bitcoinknots/guix.sigs/knots/builder-keys/luke-jr.gpg

# CONVOY gateway master (b9ea7dc) plus the duplicate-share use-after-free fix
# from CONVOYMining/datum_gateway#18, which is reviewed but not merged yet.
# Fetched by commit hash, so nothing pushed later can change what gets built.
GW_REPO=https://github.com/CONVOYMining/datum_gateway.git
GW_COMMIT=6ccfbe55a7e7cd6c066aa428e771a37a22e92277

COMMANDS=(git curl gpg python3 ip make cc cmake pkg-config)
LIBS=(libcurl jansson libsodium libmicrohttpd)
STRATUM_PORT=23334
API_PORT=7152
PRUNE_MB=2000
DEFAULT_TAG1="DATUM Gateway"

HOME_DIR=${HOME:?}
BASE=$HOME_DIR/knots-datum-node
BIN=$BASE/bin
DATA=$BASE/bitcoin
GW_STATE=$BASE/gateway
CONF=$BASE/conf
UNITS=$HOME_DIR/.config/systemd/user
NODE_UNIT=knots-datum-node-bitcoind.service
GW_UNIT=knots-datum-node-gateway.service
MINER_IPS=()

die() { echo; echo "error: $*" >&2; exit 1; }
say() { echo; echo "== $*"; }

export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
user_systemctl() { systemctl --user "$@"; }

# The one line an administrator runs to install what the scripts need.
if command -v apt-get >/dev/null 2>&1; then
	PKG_INSTALL="sudo apt-get update && sudo apt-get install -y git curl gnupg ca-certificates python3 iproute2 build-essential cmake pkgconf libcurl4-openssl-dev libjansson-dev libsodium-dev libmicrohttpd-dev"
	UFW_INSTALL="sudo apt-get install -y ufw"
elif command -v dnf >/dev/null 2>&1; then
	PKG_INSTALL="sudo dnf install -y git curl gnupg2 ca-certificates python3 iproute gcc make cmake pkgconf libcurl-devel jansson-devel libsodium-devel libmicrohttpd-devel"
	FIREWALLD_INSTALL="sudo dnf install -y firewalld && sudo systemctl enable --now firewalld"
elif command -v pacman >/dev/null 2>&1; then
	PKG_INSTALL="sudo pacman -S --needed git curl gnupg python iproute2 base-devel cmake pkgconf jansson libsodium libmicrohttpd"
	UFW_INSTALL="sudo pacman -S --needed ufw && sudo systemctl enable --now ufw"
elif command -v zypper >/dev/null 2>&1; then
	PKG_INSTALL="sudo zypper install -y git curl gpg2 python3 iproute2 gcc make cmake pkg-config libcurl-devel libjansson-devel libsodium-devel libmicrohttpd-devel"
	FIREWALLD_INSTALL="sudo zypper install -y firewalld && sudo systemctl enable --now firewalld"
else
	PKG_INSTALL="# install these with your package manager: git, curl, gpg, python3, iproute2, a C compiler, make, cmake, pkg-config, and the development packages for libcurl, jansson, libsodium and libmicrohttpd"
	UFW_INSTALL="# install a firewall (ufw or firewalld)"
fi

require_python() {
	command -v python3 >/dev/null 2>&1 && return 0
	echo; echo "Before this can run, someone with admin rights needs to run:"; echo; echo "    $PKG_INSTALL"
	exit 1
}

# --- settings -------------------------------------------------------------
#
# ADDRESS, MODE (pool or solo), POOL_HOST/POOL_PORT/POOL_PUBKEY (empty host
# means CONVOY, the gateway's default), TAG1 (primary coinbase tag, used in
# solo mode only; a pool puts its own there), TAG2 (secondary tag), UNIQUE_ID.
# Command line flags go in F_* and win over whatever is already saved.

F_ADDRESS= F_MODE= F_POOL_HOST= F_POOL_PUBKEY= F_TAG1= F_TAG2= F_TAG1_SET=0 F_TAG2_SET=0

# Handles one settings flag. Returns 1 if $1 is not one, so callers can go on
# to their own flags. Sets SHIFT to how many arguments it used.
parse_setting_flag() {
	SHIFT=2
	case "$1" in
		--address) F_ADDRESS=${2-} ;;
		--mode) F_MODE=${2-} ;;
		--pool-host) F_POOL_HOST=${2-} ;;
		--pool-pubkey) F_POOL_PUBKEY=${2-} ;;
		--primary-tag) F_TAG1=${2-}; F_TAG1_SET=1 ;;
		--tag) F_TAG2=${2-}; F_TAG2_SET=1 ;;
		*) return 1 ;;
	esac
	[ $# -ge 2 ] || die "$1 needs a value"
}

# Saved settings from an earlier install, if there are any.
load_saved_settings() {
	S_ADDRESS= S_MODE= S_POOL_HOST= S_POOL_PORT= S_POOL_PUBKEY= S_TAG1= S_TAG2= S_UNIQUE_ID= S_RPC_PASS= S_API_PASS=
	HAVE_SAVED=0
	[ -f "$CONF/datum_gateway.json" ] || return 0
	eval "$(python3 - "$CONF/datum_gateway.json" <<'PY'
import json, shlex, sys
j = json.load(open(sys.argv[1]))
m, d, b, a = j.get("mining", {}), j.get("datum", {}), j.get("bitcoind", {}), j.get("api", {})
host = d.get("pool_host")
mode = "solo" if host == "" else "pool"
v = {
	"S_ADDRESS": m.get("pool_address", ""),
	"S_MODE": mode,
	"S_POOL_HOST": host or "",
	"S_POOL_PORT": str(d.get("pool_port", "")) if host else "",
	"S_POOL_PUBKEY": d.get("pool_pubkey", "") if host else "",
	"S_TAG1": m.get("coinbase_tag_primary", ""),
	"S_TAG2": m.get("coinbase_tag_secondary", ""),
	"S_UNIQUE_ID": str(m.get("coinbase_unique_id", "")),
	"S_RPC_PASS": b.get("rpcpassword", ""),
	"S_API_PASS": a.get("admin_password", ""),
}
for k, val in v.items():
	print("%s=%s" % (k, shlex.quote(val)))
PY
)"
	HAVE_SAVED=1
}

check_address() {
	[ "$1" != YOUR-ADDRESS ] || { echo "replace YOUR-ADDRESS with your own Bitcoin address"; return 1; }
	[[ "$1" =~ ^(bc1[02-9ac-hj-np-z]{11,87}|[13][1-9A-HJ-NP-Za-km-z]{25,34})$ ]] && return 0
	echo "${1:-that} does not look like a Bitcoin address. Use the address your mining rewards should go to; it starts with bc1, 1 or 3."
	return 1
}
check_mode() {
	case "$1" in pool|solo) return 0 ;; esac
	echo "type pool or solo"; return 1
}
check_tag() {	# $1 = tag, $2 = what to call it
	local LC_ALL=C
	[ ${#1} -le 60 ] || { echo "$2 is too long: 60 characters at most"; return 1; }
	[[ "$1" =~ ^[\ -~]*$ ]] && [[ "$1" != *'"'* ]] && [[ "$1" != *'\'* ]] && return 0
	echo "$2 can use plain letters, numbers, spaces and punctuation, but no quotes or backslashes"
	return 1
}
check_pool_host() {	# accepts host or host:port; sets POOL_HOST and POOL_PORT
	[[ "$1" =~ ^[A-Za-z0-9.-]{1,253}(:[0-9]{1,5})?$ ]] || { echo "type a host name or IP address, optionally with :port"; return 1; }
	local h=$1 p=28915
	if [[ "$h" == *:* ]]; then p=${h##*:}; h=${h%:*}; fi
	[ "$p" -ge 1 ] && [ "$p" -le 65535 ] || { echo "port must be between 1 and 65535"; return 1; }
	POOL_HOST=$h POOL_PORT=$p
}
check_pubkey() {
	[[ "$1" =~ ^[0-9a-f]{128}$ ]] && return 0
	echo "a DATUM pool key is 128 characters of 0-9 and a-f"; return 1
}

# ask VAR "question" "default" check_function [check args]
# Keeps asking until the answer passes the check. Enter keeps the default.
ask() {
	local var=$1 q=$2 def=$3 check=$4 ans msg show
	shift 4
	show=${def:-none}
	while :; do
		read -r -p "$q [$show]: " ans || die "no answer given"
		ans=${ans:-$def}
		[ "$ans" = - ] && ans=
		if msg=$("$check" "$ans" "$@"); then
			printf -v "$var" '%s' "$ans"
			return 0
		fi
		echo "  $msg"
	done
}

# Works out the settings from flags, then saved values, then defaults. Asks
# about each one when run in a terminal (unless NO_PROMPT=1); otherwise the
# flags and saved values have to be enough.
settle_settings() {
	local interactive=0
	[ -t 0 ] && [ -t 1 ] && [ "${NO_PROMPT:-0}" = 0 ] && interactive=1

	ADDRESS=${F_ADDRESS:-$S_ADDRESS}
	MODE=${F_MODE:-${S_MODE:-pool}}
	POOL_HOST=${S_POOL_HOST} POOL_PORT=${S_POOL_PORT} POOL_PUBKEY=${S_POOL_PUBKEY}
	[ -z "$F_POOL_HOST" ] || POOL_HOST=$F_POOL_HOST POOL_PORT=
	[ -z "$F_POOL_PUBKEY" ] || POOL_PUBKEY=$F_POOL_PUBKEY
	TAG1=${S_TAG1:-$DEFAULT_TAG1}; [ $F_TAG1_SET = 0 ] || TAG1=$F_TAG1
	TAG2=$S_TAG2; [ $F_TAG2_SET = 0 ] || TAG2=$F_TAG2
	UNIQUE_ID=${S_UNIQUE_ID:-$(python3 -c 'import secrets; print(secrets.randbelow(65535) + 1)')}

	if [ $interactive = 1 ]; then
		echo
		echo "Answer each question, or press Enter to keep the value in [brackets]."
		echo
		ask ADDRESS "Bitcoin address for your mining rewards" "$ADDRESS" check_address
		echo
		echo "Mine with a pool, or solo?"
		echo "  pool: your node builds the blocks, the pool counts your work and pays"
		echo "        you a share of what everyone finds. Steady, smaller payouts."
		echo "  solo: you get the whole reward for any block you find, and nothing"
		echo "        otherwise. With a small miner that can mean a very long wait."
		ask MODE "pool or solo" "$MODE" check_mode
		if [ "$MODE" = pool ]; then
			local current=CONVOY
			[ -z "$POOL_HOST" ] || current=$POOL_HOST:$POOL_PORT
			echo
			echo "Which DATUM pool? Press Enter for CONVOY, or type another pool's"
			echo "server address (type convoy to go back to CONVOY)."
			local answer
			ask answer "pool server" "$current" check_pool_choice
			if [ "${answer,,}" = convoy ]; then
				POOL_HOST= POOL_PORT= POOL_PUBKEY=
			else
				check_pool_host "$answer" >/dev/null
				ask POOL_PUBKEY "That pool's public key (its operator publishes it)" "$POOL_PUBKEY" check_pubkey
			fi
		else
			echo
			echo "Solo blocks carry a name in them that anyone can read."
			ask TAG1 "name written into blocks you find" "$TAG1" check_tag "the name"
		fi
		echo
		echo "You can also add a short name of your own to your blocks. Anyone can read"
		echo "it, so leave it empty to stay anonymous. Type - for none."
		ask TAG2 "your short name" "$TAG2" check_tag "your short name"
	fi

	local msg
	[ -n "$ADDRESS" ] || die "a payout address is needed: run this in a terminal to be asked, or pass --address"
	msg=$(check_address "$ADDRESS") || die "$msg"
	msg=$(check_mode "$MODE") || die "$msg"
	msg=$(check_tag "$TAG1" "the primary tag") || die "$msg"
	msg=$(check_tag "$TAG2" "the secondary tag") || die "$msg"
	[ $(( ${#TAG1} + ${#TAG2} )) -le 88 ] || die "the two tags together can be 88 characters at most"
	if [ "$MODE" = pool ] && [ -n "$POOL_HOST" ]; then
		if [ -z "$POOL_PORT" ]; then msg=$(check_pool_host "$POOL_HOST") || die "$msg"; check_pool_host "$POOL_HOST" >/dev/null; fi
		[ -n "$POOL_PUBKEY" ] || die "a pool other than CONVOY needs its public key (--pool-pubkey)"
		msg=$(check_pubkey "$POOL_PUBKEY") || die "$msg"
	fi
	[ "$MODE" = pool ] || { POOL_HOST= POOL_PORT= POOL_PUBKEY=; }
	return 0
}

check_pool_choice() {
	[ "${1,,}" = convoy ] && return 0
	check_pool_host "$1"
}

show_settings() {
	echo "  payout address: $ADDRESS"
	if [ "$MODE" = pool ]; then
		if [ -n "$POOL_HOST" ]; then echo "  mining:         pool, $POOL_HOST:$POOL_PORT"; else echo "  mining:         pool, CONVOY"; fi
	else
		echo "  mining:         solo, blocks named \"$TAG1\""
	fi
	echo "  your name:      ${TAG2:-(none)}"
}

# --- files ----------------------------------------------------------------
#
# Everything the install writes comes from these functions, so --dry-run
# prints exactly what a real run would put on disk.

render_bitcoin_conf() {	# $1 = rpcauth value
	cat <<EOF
server=1
prune=$PRUNE_MB
dbcache=$DBCACHE
maxmempool=300
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
rpcauth=$1
rpcwhitelist=gateway:getbestblockhash,getblock,getblocktemplate,submitblock,preciousblock
rpcwhitelistdefault=0
blocknotify=curl -s -m 5 -o /dev/null http://127.0.0.1:$API_PORT/NOTIFY
EOF
}

render_gateway_json() {	# $1 = RPC password, $2 = dashboard admin password
	local datum
	if [ "$MODE" = pool ]; then
		# miners' worker names are appended to the payout address as <address>.<worker>
		datum='"pool_pass_workers": true, "pool_pass_full_users": false, "pooled_mining_only": true'
		if [ -n "$POOL_HOST" ]; then
			datum+=", \"pool_host\": \"$POOL_HOST\", \"pool_port\": $POOL_PORT, \"pool_pubkey\": \"$POOL_PUBKEY\""
		fi
	else
		datum='"pool_host": "", "pooled_mining_only": false'
	fi
	cat <<EOF
{
  "bitcoind": {
    "rpcuser": "gateway",
    "rpcpassword": "$1",
    "rpcurl": "http://127.0.0.1:8332",
    "notify_fallback": true
  },
  "stratum": { "listen_port": $STRATUM_PORT, "max_clients": 256 },
  "mining": {
    "pool_address": "$ADDRESS",
    "coinbase_tag_primary": "$TAG1",
    "coinbase_tag_secondary": "$TAG2",
    "coinbase_unique_id": $UNIQUE_ID,
    "pow_algorithm": "auto"
  },
  "api": {
    "listen_addr": "127.0.0.1",
    "listen_port": $API_PORT,
    "admin_password": "$2",
    "modify_conf": false
  },
  "logger": { "log_to_console": true, "log_to_file": false, "log_level_console": 2 },
  "datum": { $datum }
}
EOF
}

render_node_unit() {
	cat <<EOF
[Unit]
Description=Bitcoin Knots (knots-datum-node)

[Service]
ExecStart=$BIN/bitcoind -conf=$CONF/bitcoin.conf -datadir=$DATA
ExecStop=$BIN/bitcoin-cli -conf=$CONF/bitcoin.conf -datadir=$DATA stop
TimeoutStartSec=600
TimeoutStopSec=600
Restart=on-failure
NoNewPrivileges=true

[Install]
WantedBy=default.target
EOF
}

render_gateway_unit() {
	cat <<EOF
[Unit]
Description=DATUM Gateway (knots-datum-node)
After=$NODE_UNIT
Requires=$NODE_UNIT

[Service]
WorkingDirectory=$GW_STATE
ExecStart=$BIN/datum_gateway --config $CONF/datum_gateway.json
Restart=always
RestartSec=10
LimitNOFILE=100000
MemoryMax=1G
UMask=0077
# The gateway talks to other people's miners. Limit what it can do.
NoNewPrivileges=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictRealtime=true
RestrictSUIDSGID=true
RestrictNamespaces=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources

[Install]
WantedBy=default.target
EOF
}

render_status_script() {
	cat <<EOF
#!/bin/bash
# Shows how far the node has synced and whether the gateway is running.
export XDG_RUNTIME_DIR=\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}
cli() { $BIN/bitcoin-cli -conf=$CONF/bitcoin.conf -datadir=$DATA "\$@"; }
synced=no
if ! systemctl --user is-active --quiet $NODE_UNIT; then
	echo "node: NOT running (see: journalctl --user -u $NODE_UNIT)"
elif ! out=\$(cli getblockchaininfo 2>&1); then
	echo "node: starting up"
else
	python3 -c 'import json,sys; j=json.loads(sys.argv[1]); print("node: getting the list of blocks from other nodes, miners cannot connect yet" if j["headers"] == 0 else "node: %s, block %d of %d, %.1f%% checked" % ("still syncing, miners cannot connect yet" if j["initialblockdownload"] else "synced", j["blocks"], j["headers"], 100*j["verificationprogress"]))' "\$out"
	python3 -c 'import json,sys; sys.exit(1 if json.loads(sys.argv[1])["initialblockdownload"] else 0)' "\$out" && synced=yes
	echo "connected to \$(cli getconnectioncount) other nodes"
fi
if systemctl --user is-active --quiet $GW_UNIT; then echo "gateway: running"; else echo "gateway: NOT running"; fi
# The gateway logs errors while the node syncs; they only matter once it has.
[ \$synced = yes ] && journalctl --user -u $GW_UNIT -n 5 --no-pager -o cat 2>/dev/null
exit 0
EOF
}

firewall_commands() {
	local ip family
	if command -v firewall-cmd >/dev/null 2>&1 || [ -n "${FIREWALLD_INSTALL:-}" ]; then
		command -v firewall-cmd >/dev/null 2>&1 || echo "$FIREWALLD_INSTALL"
		echo "sudo firewall-cmd --permanent --add-port=8333/tcp"
		[ ${#MINER_IPS[@]} -gt 0 ] || echo "sudo firewall-cmd --permanent --add-port=$STRATUM_PORT/tcp"
		for ip in "${MINER_IPS[@]}"; do
			family=ipv4; [[ "$ip" == *:* ]] && family=ipv6
			echo "sudo firewall-cmd --permanent --add-rich-rule='rule family=\"$family\" source address=\"$ip\" port port=\"$STRATUM_PORT\" protocol=\"tcp\" accept'"
		done
		echo "sudo firewall-cmd --reload"
	else
		echo "${UFW_INSTALL:-# install ufw with your package manager}"
		echo "sudo ufw allow ssh"
		echo "sudo ufw allow 8333/tcp"
		[ ${#MINER_IPS[@]} -gt 0 ] || echo "sudo ufw allow $STRATUM_PORT/tcp"
		for ip in "${MINER_IPS[@]}"; do echo "sudo ufw allow from $ip to any port $STRATUM_PORT proto tcp"; done
		echo "sudo ufw enable"
	fi
}
