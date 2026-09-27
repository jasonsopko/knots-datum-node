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
# CONVOY's pool server, from the gateway's own defaults at GW_COMMIT. Written
# into the config so the dashboard and the file both say which pool is used.
CONVOY_HOST=datum-beta1.mine.convoy.xyz
CONVOY_PORT=28915
CONVOY_PUBKEY=dbb11fa0c2b5403e4f798fa6071bb97e6079d219598366032fdf2ae01962b13c5e66e2be7d6b008f0b2603f3e6f6fc64768fa786c8129c46d3e30a5867734b62
# What the gateway's node login may call: the five the gateway uses, plus
# three read-only ones for the status command and the connection check.
RPC_METHODS=getbestblockhash,getblock,getblocktemplate,submitblock,preciousblock,getblockchaininfo,getnetworkinfo,getconnectioncount
LOCAL_RPC_URL=http://127.0.0.1:8332
EXT_RPC_USER=knotsdatum

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

# This computer's address, and whether it is a private (home or office)
# address or one on the open internet.
OWN_IP=$(ip -4 route get 192.0.2.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}' || true)
OWN_PRIVATE=0 LAN_CIDR=
if [ -n "$OWN_IP" ] && python3 -c 'import ipaddress,sys; sys.exit(0 if ipaddress.ip_address(sys.argv[1]).is_private else 1)' "$OWN_IP" 2>/dev/null; then
	OWN_PRIVATE=1
	LAN_CIDR=$(ip -o -4 addr show 2>/dev/null | awk -v ip="$OWN_IP" '{split($4, a, "/"); if (a[1] == ip) print $4}' | head -1 || true)
	[ -z "$LAN_CIDR" ] || LAN_CIDR=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1], strict=False))' "$LAN_CIDR")
fi
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
# NODE: "new" (a Knots node this installs and runs here) or "existing" (a
# node the user already runs), reached at RPC_URL with RPC_USER/RPC_PASS.
# ADDRESS, MODE (pool or solo), POOL_HOST/POOL_PORT/POOL_PUBKEY (empty host
# means CONVOY, the gateway's default), TAG1 (primary coinbase tag, used in
# solo mode only; a pool puts its own there), TAG2 (secondary tag), UNIQUE_ID.
# SHARED (yes or no, pool mode only): whether miners' usernames go to the pool
# as their own payout addresses, so other people can mine through this gateway.
# Command line flags go in F_* and win over whatever is already saved.

F_ADDRESS= F_MODE= F_POOL_HOST= F_POOL_PUBKEY= F_TAG1= F_TAG2= F_TAG1_SET=0 F_TAG2_SET=0
F_NODE= F_RPC_USER= F_DASH_OPEN= F_SHARED=

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
		--node) F_NODE=${2-} ;;
		--rpc-user) F_RPC_USER=${2-} ;;
		--dashboard) F_DASH_OPEN=${2-} ;;
		--shared) F_SHARED=${2-} ;;
		*) return 1 ;;
	esac
	[ $# -ge 2 ] || die "$1 needs a value"
}

# Saved settings from an earlier install, if there are any.
load_saved_settings() {
	S_ADDRESS= S_MODE= S_POOL_HOST= S_POOL_PORT= S_POOL_PUBKEY= S_TAG1= S_TAG2= S_UNIQUE_ID= S_RPC_PASS= S_API_PASS=
	S_RPC_URL= S_RPC_USER= S_NODE= S_DASH_OPEN= S_SHARED=
	HAVE_SAVED=0
	[ -f "$CONF/datum_gateway.json" ] || return 0
	eval "$(python3 - "$CONF/datum_gateway.json" "$CONVOY_HOST" <<'PY'
import json, shlex, sys
j = json.load(open(sys.argv[1]))
m, d, b, a = j.get("mining", {}), j.get("datum", {}), j.get("bitcoind", {}), j.get("api", {})
host = d.get("pool_host")
mode = "solo" if host == "" else "pool"
v = {
	"S_ADDRESS": m.get("pool_address", ""),
	"S_MODE": mode,
	"S_POOL_HOST": "" if host == sys.argv[2] else (host or ""),
	"S_POOL_PORT": str(d.get("pool_port", "")) if host else "",
	"S_POOL_PUBKEY": d.get("pool_pubkey", "") if host else "",
	"S_TAG1": m.get("coinbase_tag_primary", ""),
	"S_TAG2": m.get("coinbase_tag_secondary", ""),
	"S_UNIQUE_ID": str(m.get("coinbase_unique_id", "")),
	"S_RPC_PASS": b.get("rpcpassword", ""),
	"S_RPC_URL": b.get("rpcurl", ""),
	"S_RPC_USER": b.get("rpcuser", ""),
	"S_API_PASS": a.get("admin_password", ""),
	"S_DASH_OPEN": "local" if a.get("listen_addr", "127.0.0.1") == "127.0.0.1" else "network",
	"S_SHARED": "yes" if host and d.get("pool_pass_full_users", True) else "no",
}
for k, val in v.items():
	print("%s=%s" % (k, shlex.quote(val)))
PY
)"
	HAVE_SAVED=1
	# The node unit is only there when this installed the node.
	if [ -f "$UNITS/$NODE_UNIT" ]; then S_NODE=new; else S_NODE=existing; fi
}

check_address() {
	[ "$1" != YOUR-ADDRESS ] || { echo "replace YOUR-ADDRESS with your own Bitcoin address"; return 1; }
	if ! [[ "$1" =~ ^(bc1[02-9ac-hj-np-z]{11,87}|[13][1-9A-HJ-NP-Za-km-z]{25,34})$ ]]; then
		echo "${1:-that} does not look like a Bitcoin address. Use the address your mining rewards should go to; it starts with bc1, 1 or 3."
		return 1
	fi
	address_checksum_ok "$1" && return 0
	echo "$1 has a typo in it: its checksum does not match. Copy it from your wallet again; do not type it by hand."
	return 1
}
# The checksum built into every address (bech32/bech32m for bc1, base58check
# for 1 and 3) catches almost any typo. The gateway checks it too, but only
# after the install, by refusing to start.
address_checksum_ok() {
	python3 - "$1" <<'PY'
import hashlib, sys
a = sys.argv[1]
if a.startswith("bc1"):
	cs = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
	def polymod(v):
		c = 1
		for x in v:
			b = c >> 25
			c = (c & 0x1ffffff) << 5 ^ x
			for i in range(5):
				c ^= (0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3)[i] if (b >> i) & 1 else 0
		return c
	d = [cs.index(ch) for ch in a[3:]]
	k = polymod([3, 3, 0, 2, 3] + d)
	# witness v0 uses bech32, v1 and later bech32m
	sys.exit(0 if (d[0] == 0 and k == 1) or (d[0] != 0 and k == 0x2bc830a3) else 1)
alpha = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
n = 0
for ch in a:
	n = n * 58 + alpha.index(ch)
raw = n.to_bytes(25, "big") if n.bit_length() <= 200 else b""
sys.exit(0 if len(raw) == 25 and raw[0] in (0, 5) and hashlib.sha256(hashlib.sha256(raw[:21]).digest()).digest()[:4] == raw[21:] else 1)
PY
}
check_dash_password() {
	local LC_ALL=C
	[ -z "$1" ] && return 0
	[ ${#1} -ge 8 ] || { echo "use at least 8 characters"; return 1; }
	[ ${#1} -le 64 ] || { echo "use at most 64 characters"; return 1; }
	[[ "$1" =~ ^[\!-~]+$ ]] && [[ "$1" != *'"'* ]] && [[ "$1" != *'\'* ]] && return 0
	echo "use letters, numbers and punctuation, with no spaces, quotes or backslashes"; return 1
}
check_dash_open() {
	case "$1" in network|local) return 0 ;; esac
	echo "type network or local"; return 1
}
check_mode() {
	case "$1" in pool|solo) return 0 ;; esac
	echo "type pool or solo"; return 1
}
check_shared() {
	case "$1" in yes|no) return 0 ;; esac
	echo "type yes or no"; return 1
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
		read -e -r -p "$q [$show]: " ans || die "no answer given"
		ans=${ans:-$def}
		[ "$ans" = - ] && ans=
		if msg=$("$check" "$ans" "$@"); then
			printf -v "$var" '%s' "$ans"
			return 0
		fi
		echo "  $msg"
	done
}

check_node_choice() {
	case "$1" in new|existing) return 0 ;; esac
	echo "type new or existing"; return 1
}
check_node_addr() {	# host or host:port; sets NODE_HOST and NODE_PORT
	[[ "$1" =~ ^[A-Za-z0-9.-]{1,253}(:[0-9]{1,5})?$ ]] || { echo "type the node's IP address or name, optionally with :port"; return 1; }
	local h=$1 p=8332
	if [[ "$h" == *:* ]]; then p=${h##*:}; h=${h%:*}; fi
	[ "$p" -ge 1 ] && [ "$p" -le 65535 ] || { echo "port must be between 1 and 65535"; return 1; }
	NODE_HOST=$h NODE_PORT=$p
}
check_any() { return 0; }
# Something already answering on this computer's RPC port that this did not install.
other_local_node() {
	[ -f "$UNITS/$NODE_UNIT" ] && return 1
	ss -Hltn "sport = :8332" 2>/dev/null | grep -q .
}

# Asks the node the questions the gateway will ask. Prints one line saying
# what it found. Returns 0 if it is ready, 3 if it works but is still syncing,
# 1 if it cannot be used.
node_check() {	# $1 url, $2 user, $3 password
	python3 - "$1" "$2" "$3" <<'PY'
import base64, json, socket, sys, urllib.error, urllib.request
url, user, pw = sys.argv[1:4]
auth = "Basic " + base64.b64encode(("%s:%s" % (user, pw)).encode()).decode()
def call(method, params=None):
	body = json.dumps({"jsonrpc": "1.0", "id": "check", "method": method, "params": params or []}).encode()
	req = urllib.request.Request(url, data=body, headers={"Authorization": auth, "Content-Type": "application/json"})
	try:
		return json.load(urllib.request.urlopen(req, timeout=15))
	except urllib.error.HTTPError as e:
		if e.code == 401:
			print("the node turned down the username or password")
			sys.exit(1)
		if e.code == 403:
			print("the login works, but the node does not let it call %s: check the rpcwhitelist line" % method)
			sys.exit(1)
		try:
			return json.load(e)
		except Exception:
			print("the node answered with HTTP error %d" % e.code)
			sys.exit(1)
	except (urllib.error.URLError, socket.timeout, OSError) as e:
		reason = getattr(e, "reason", e)
		print("could not reach a node at %s (%s). Is it running, and does it accept RPC connections from this computer (rpcbind, rpcallowip, firewall)?" % (url, reason))
		sys.exit(1)
info = call("getblockchaininfo").get("result") or {}
net = call("getnetworkinfo").get("result") or {}
version = net.get("subversion", "unknown version").strip("/")
gbt = call("getblocktemplate", [{"rules": ["segwit", "blake2b"]}])
syncing = info.get("initialblockdownload", False)
if gbt.get("error"):
	if syncing:
		print("found %s, still syncing (block %s of %s); the gateway will start once it catches up" % (version, info.get("blocks"), info.get("headers")))
		sys.exit(3)
	print("found %s, but it would not give a block template: %s" % (version, gbt["error"].get("message")))
	sys.exit(1)
rules = (gbt.get("result") or {}).get("rules", [])
if not any("blake2b" in r for r in rules):
	chain = info.get("chain", "main")
	if chain != "main":
		print("found %s on the %s network, where it does not build BLAKE2b blocks yet. Use a mainnet node." % (version, chain))
	else:
		print("found %s, but it does not build BLAKE2b blocks. It needs Bitcoin Knots 29.4.1 or later." % version)
	sys.exit(1)
print("found %s at block %s, building BLAKE2b blocks" % (version, info.get("blocks")))
PY
}

# The lines an existing node needs for the gateway's new login.
node_conf_lines() {	# $1 = rpcauth value
	echo "rpcauth=$1"
	echo "rpcwhitelist=$EXT_RPC_USER:$RPC_METHODS"
	echo "rpcwhitelistdefault=0"
	if [ "$NODE_HOST" != 127.0.0.1 ] && [ "$NODE_HOST" != localhost ]; then
		local me
		me=$(ip -4 route get "$(getent ahostsv4 "$NODE_HOST" | awk '{print $1; exit}')" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}' || true)
		[ -n "$me" ] || me="<this computer's IP>"
		echo "rpcallowip=$me"
		echo "rpcbind=${NODE_HOST}"
	fi
}

new_rpcauth() {	# $1 user, $2 password
	python3 -c 'import hmac,secrets,sys; s=secrets.token_hex(16); print("%s:%s$%s" % (sys.argv[1], s, hmac.new(s.encode(), sys.argv[2].encode(), "sha256").hexdigest()))' "$1" "$2"
}

# Which node the gateway uses. Sets NODE, RPC_URL, RPC_USER, and RPC_PASS
# (empty for a new node; the install makes one).
settle_node() {	# $1 = 1 if interactive
	local interactive=$1 msg rc
	NODE=${S_NODE:-new}
	if [ -n "$F_NODE" ]; then
		if [ "$F_NODE" = new ]; then NODE=new; else NODE=existing; msg=$(check_node_addr "$F_NODE") || die "--node: $msg"; check_node_addr "$F_NODE"; fi
	elif [ "$NODE" = existing ]; then
		local saved=${S_RPC_URL#http://}; saved=${saved%/}
		check_node_addr "$saved" >/dev/null && check_node_addr "$saved"
	fi
	[ -z "$F_NODE" ] && [ -z "$S_NODE" ] && other_local_node && NODE=existing && NODE_HOST=127.0.0.1 NODE_PORT=8332

	if [ $interactive = 1 ]; then
		echo
		if other_local_node; then
			echo "A Bitcoin node is already running on this computer (port 8332)."
			echo
		fi
		cat <<'TEXT'
Which Bitcoin node should your gateway use?

  new       Install Bitcoin Knots here. It downloads and checks the whole
            chain before your miners can connect: a day or more, and about
            800 GB of internet data.

  existing  Use a Bitcoin Knots node you already run, on this computer or
            on your network. It needs to be version 29.4.1 or later, the
            versions that build BLAKE2b blocks.

TEXT
		ask NODE "new or existing" "$NODE" check_node_choice
	fi

	if [ "$NODE" = new ]; then
		other_local_node && die "a Bitcoin node is already running on this computer, and a second one would clash with it. Choose existing to use it, or stop it first."
		RPC_URL=$LOCAL_RPC_URL RPC_USER=gateway
		RPC_PASS=; [ "$S_NODE" = new ] && RPC_PASS=$S_RPC_PASS
		return 0
	fi

	local addr=${NODE_HOST:-127.0.0.1}:${NODE_PORT:-8332}
	RPC_USER=${F_RPC_USER:-${S_RPC_USER:-}}
	[ "$S_NODE" = existing ] || [ -n "$F_RPC_USER" ] || RPC_USER=
	RPC_PASS=${NODE_RPC_PASSWORD:-}
	[ -n "$RPC_PASS" ] || { [ "$RPC_USER" = "$S_RPC_USER" ] && [ "$S_NODE" = existing ] && RPC_PASS=$S_RPC_PASS; } || true

	local need_ask=1
	while :; do
		if [ $interactive = 1 ] && [ $need_ask = 1 ]; then
			need_ask=0
			echo
			ask addr "Your node's address (IP or name, and :port if not 8332)" "$addr" check_node_addr
			check_node_addr "$addr"
			echo
			echo "The gateway needs a login on your node. Press Enter to make a new one"
			echo "only for the gateway (recommended), or type the RPC username you use now."
			local who=${RPC_USER:-new}
			ask who "login" "$who" check_any
			if [ "$who" = new ] || { [ "$who" = "$EXT_RPC_USER" ] && [ -z "$RPC_PASS" ]; }; then
				RPC_USER=$EXT_RPC_USER
				RPC_PASS=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
				echo
				echo "Add these lines to the bitcoin.conf of the node at $NODE_HOST, then restart"
				echo "that node:"
				echo
				node_conf_lines "$(new_rpcauth "$RPC_USER" "$RPC_PASS")" | sed 's/^/    /'
				echo
				echo "rpcwhitelistdefault=0 keeps the node's other logins working as they do"
				echo "now; without it, adding a whitelist line locks them out. If your"
				echo "bitcoin.conf already sets rpcwhitelistdefault, keep your own setting."
				if [ "$NODE_HOST" != 127.0.0.1 ]; then
					echo "If that bitcoin.conf already has an rpcbind line covering this address"
					echo "(rpcbind=0.0.0.0 covers all of them), leave the rpcbind line out. The same"
					echo "goes for rpcallowip, if an existing line already allows this computer."
				fi
				echo
				read -e -r -p "Press Enter once the node has restarted. " _ || die "no answer given"
			elif [ "$who" != "$RPC_USER" ] || [ -z "$RPC_PASS" ]; then
				RPC_USER=$who
				read -r -s -p "Password for $RPC_USER: " RPC_PASS || die "no answer given"; echo
			fi
		fi
		[ -n "$RPC_USER" ] && [ -n "$RPC_PASS" ] || die "an existing node needs a login: run this in a terminal to be asked, or pass --rpc-user and set NODE_RPC_PASSWORD"
		RPC_URL=http://$NODE_HOST:$NODE_PORT
		echo
		echo "Checking the node at $NODE_HOST:$NODE_PORT..."
		msg=$(node_check "$RPC_URL" "$RPC_USER" "$RPC_PASS") && rc=0 || rc=$?
		echo "  $msg"
		[ $rc = 0 ] || [ $rc = 3 ] && return 0
		[ $interactive = 1 ] || die "the node is not usable yet, see above"
		local again
		read -e -r -p "Press Enter to check again, c to change the address or login, or q to stop: " again || die "no answer given"
		case "${again,,}" in q) exit 1 ;; c) need_ask=1 ;; esac
	done
}

# Works out the settings from flags, then saved values, then defaults. Asks
# about each one when run in a terminal (unless NO_PROMPT=1); otherwise the
# flags and saved values have to be enough.
settle_settings() {
	local interactive=0 msg
	[ -t 0 ] && [ -t 1 ] && [ "${NO_PROMPT:-0}" = 0 ] && interactive=1

	ADDRESS=${F_ADDRESS:-$S_ADDRESS}
	MODE=${F_MODE:-${S_MODE:-pool}}
	SHARED=${F_SHARED:-${S_SHARED:-no}}
	POOL_HOST=${S_POOL_HOST} POOL_PORT=${S_POOL_PORT} POOL_PUBKEY=${S_POOL_PUBKEY}
	[ -z "$F_POOL_HOST" ] || POOL_HOST=$F_POOL_HOST POOL_PORT=
	[ -z "$F_POOL_PUBKEY" ] || POOL_PUBKEY=$F_POOL_PUBKEY
	TAG1=${S_TAG1:-$DEFAULT_TAG1}; [ $F_TAG1_SET = 0 ] || TAG1=$F_TAG1
	TAG2=$S_TAG2; [ $F_TAG2_SET = 0 ] || TAG2=$F_TAG2
	UNIQUE_ID=${S_UNIQUE_ID:-$(python3 -c 'import secrets; print(secrets.randbelow(65535) + 1)')}

	if [ $interactive = 1 ]; then
		echo
		echo "Answer each question, or press Enter to keep the value in [brackets]."
	fi
	settle_node $interactive
	if [ $interactive = 1 ]; then
		echo
		cat <<'TEXT'
Your payout address is where every reward goes. Take it from a wallet you
control and copy and paste it; do not type it. Nobody can send back a
reward paid to a wrong address, and a pool pays out on whatever address it
is given without checking that it is yours.
TEXT
		ask ADDRESS "Bitcoin address for your mining rewards" "$ADDRESS" check_address
		echo
		cat <<'TEXT'
Mine with a pool, or solo? Either way, your own node builds every block
your miners work on and chooses which transactions go in it.

  pool  Your gateway connects to a DATUM pool (CONVOY unless you pick
        another one next) and sends it proof of the work your miners do.
        When anyone mining with the pool finds a block, the reward is
        split among the pool's miners by their recent work. CONVOY pays
        each miner's share straight to their address inside that block,
        once it is above CONVOY's payout threshold. How the split and the
        threshold work: https://convoy.xyz/docs/tides
        If the pool cannot be reached, your miners pause; they do not
        switch to solo.

  solo  Nobody else is involved. If your miners find a block, the whole
        reward is paid straight to your address, inside that block. If
        they do not, you get nothing. How often you find one depends on
        your share of all the mining on the network, and there is no
        payment in between.

TEXT
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
			echo
			cat <<'TEXT'
Will other people mine through this gateway, each paid to their own address?

  no   Every miner here is yours. Miners can use any name, and all their
       work is credited to your payout address.

  yes  Each miner types its own Bitcoin address as its username, and the
       pool pays that address directly. You never hold anyone's reward.
       Your own miners can use a name that starts with a dot, such as
       .rig1, to be credited to your payout address. A miner that types
       anything else, even a mistyped address, mines for nobody: the pool
       takes the work and credits no one, with no error.

TEXT
			ask SHARED "yes or no" "$SHARED" check_shared
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

	# The gateway's web dashboard: overall stats, and behind the password,
	# each connected miner and its hashrate.
	DASH_PASS=${DASHBOARD_PASSWORD:-$S_API_PASS}
	DASH_OPEN=${F_DASH_OPEN:-$S_DASH_OPEN}
	if [ -z "$DASH_OPEN" ]; then if [ $OWN_PRIVATE = 1 ]; then DASH_OPEN=network; else DASH_OPEN=local; fi; fi
	if [ $interactive = 1 ]; then
		echo
		echo "The gateway has a web page that shows each miner connected to it and its"
		echo "hashrate, so you can check that your miners are working. You log in"
		echo "with the username admin and a password."
		local p1 p2 msg2
		while :; do
			if [ -n "$S_API_PASS" ]; then
				read -r -s -p "Dashboard password (Enter keeps the current one): " p1 || die "no answer given"; echo
			else
				read -r -s -p "Dashboard password (Enter makes one for you): " p1 || die "no answer given"; echo
			fi
			[ -n "$p1" ] || break
			if ! msg2=$(check_dash_password "$p1"); then echo "  $msg2"; continue; fi
			read -r -s -p "Type it again: " p2 || die "no answer given"; echo
			[ "$p1" = "$p2" ] && { DASH_PASS=$p1; break; }
			echo "  those did not match"
		done
		if [ $OWN_PRIVATE = 1 ]; then
			echo
			echo "Open the web page to other computers on your network (network), or only"
			echo "to this computer (local)?"
			ask DASH_OPEN "network or local" "$DASH_OPEN" check_dash_open
		else
			DASH_OPEN=local
		fi
	fi
	[ -n "$DASH_PASS" ] || DASH_PASS=$(python3 -c 'import secrets; print(secrets.token_urlsafe(12))')
	msg=$(check_dash_password "$DASH_PASS") || die "dashboard password: $msg"
	msg=$(check_dash_open "$DASH_OPEN") || die "--dashboard: $msg"
	if [ "$DASH_OPEN" = network ] && [ $OWN_PRIVATE = 0 ]; then
		die "this computer has a public internet address, so the dashboard stays on this computer. Reach it with an SSH tunnel; see the README."
	fi

	[ -n "$ADDRESS" ] || die "a payout address is needed: run this in a terminal to be asked, or pass --address"
	msg=$(check_address "$ADDRESS") || die "$msg"
	msg=$(check_mode "$MODE") || die "$msg"
	msg=$(check_shared "$SHARED") || die "--shared: $msg"
	if [ "$MODE" = solo ]; then
		# In solo mode every block pays the payout address alone; sharing
		# would mean holding other people's rewards.
		[ "$F_SHARED" != yes ] || die "--shared yes needs pool mode: in solo mode the whole reward goes to your payout address"
		SHARED=no
	fi
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

dashboard_url() {
	if [ "$DASH_OPEN" = network ]; then echo "http://${OWN_IP:-<this computer>}:$API_PORT"; else echo "http://127.0.0.1:$API_PORT"; fi
}
dashboard_help() {	# how to open it, for the end of install and configure
	local url=$(dashboard_url)
	if [ "$DASH_OPEN" = local ]; then
		url=http://127.0.0.1:$API_PORT
		echo "Your gateway's web pages are on this computer only. From your own"
		echo "computer, run this and keep it connected while you look:"
		echo "    ssh -L $API_PORT:127.0.0.1:$API_PORT $(id -un)@${OWN_IP:-<this computer>}"
		echo
	fi
	echo "Your gateway's stats (no login):    $url"
	echo "Your miners and their hashrate:     $url/clients"
	echo "  log in as admin with your dashboard password. To see it again:"
	echo "  ~/knots-datum-node/configure --show-password"
	echo "  (Safari cannot log in; use Firefox, Chrome or Edge.)"
	echo "Settings are changed with ~/knots-datum-node/configure, not on the page."
}
miner_login_help() {	# what to type into a miner, for the end of install and configure
	local ip=${OWN_IP:-"<this computer's IP>"}
	echo "    stratum+tcp://$ip:$STRATUM_PORT"
	if [ "$SHARED" = yes ]; then
		echo "    username: the miner owner's own Bitcoin address, copied from"
		echo "              their wallet, optionally followed by .name"
		echo "              (a username that starts with a dot is paid to you)"
		echo "    password: x"
	else
		echo "    username: any name for the miner   password: x"
	fi
}
show_settings() {
	if [ "$NODE" = new ]; then echo "  node:           new, installed here"; else echo "  node:           existing, at $NODE_HOST:$NODE_PORT (login $RPC_USER)"; fi
	echo "  payout address: $ADDRESS"
	if [ "$MODE" = pool ]; then
		if [ -n "$POOL_HOST" ]; then echo "  mining:         pool, $POOL_HOST:$POOL_PORT"; else echo "  mining:         pool, CONVOY"; fi
		if [ "$SHARED" = yes ]; then echo "  shared:         yes, each miner paid to its own address"; else echo "  shared:         no, all work paid to your address"; fi
	else
		echo "  mining:         solo, blocks named \"$TAG1\""
	fi
	echo "  your name:      ${TAG2:-(none)}"
	if [ "$DASH_OPEN" = network ]; then echo "  dashboard:      $(dashboard_url), open to your network"; else echo "  dashboard:      this computer only"; fi
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
rpcwhitelist=gateway:$RPC_METHODS
rpcwhitelistdefault=0
blocknotify=curl -s -m 5 -o /dev/null http://127.0.0.1:$API_PORT/NOTIFY
EOF
}

render_gateway_json() {	# $1 = RPC password, $2 = dashboard admin password
	local datum
	if [ "$MODE" = pool ]; then
		# Not shared: miners' names are appended to the payout address as
		# <address>.<name>. Shared: a miner's username goes to the pool as
		# is, so its address is paid; one that starts with a dot still gets
		# the payout address in front.
		datum="\"pool_pass_workers\": true, \"pool_pass_full_users\": $( [ "$SHARED" = yes ] && echo true || echo false ), \"pooled_mining_only\": true"
		if [ -n "$POOL_HOST" ]; then
			datum+=", \"pool_host\": \"$POOL_HOST\", \"pool_port\": $POOL_PORT, \"pool_pubkey\": \"$POOL_PUBKEY\""
		else
			datum+=", \"pool_host\": \"$CONVOY_HOST\", \"pool_port\": $CONVOY_PORT, \"pool_pubkey\": \"$CONVOY_PUBKEY\""
		fi
	else
		datum='"pool_host": "", "pooled_mining_only": false'
	fi
	cat <<EOF
{
  "bitcoind": {
    "rpcuser": "$RPC_USER",
    "rpcpassword": "$1",
    "rpcurl": "$RPC_URL",
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
    "listen_addr": "$( [ "$DASH_OPEN" = network ] && echo "" || echo 127.0.0.1 )",
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
$(if [ "$NODE" = new ]; then printf 'After=%s\nRequires=%s\n' "$NODE_UNIT" "$NODE_UNIT"; fi)

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
# Asks the node, with the gateway's own login.
rpc() {
	python3 - "$CONF/datum_gateway.json" "\$1" <<'PY'
import base64, json, sys, urllib.request
c = json.load(open(sys.argv[1]))["bitcoind"]
auth = "Basic " + base64.b64encode((c["rpcuser"] + ":" + c["rpcpassword"]).encode()).decode()
req = urllib.request.Request(c["rpcurl"], data=json.dumps({"jsonrpc": "1.0", "id": "status", "method": sys.argv[2], "params": []}).encode(), headers={"Authorization": auth, "Content-Type": "application/json"})
try:
	print(json.dumps(json.load(urllib.request.urlopen(req, timeout=10))["result"]))
except Exception:
	sys.exit(1)
PY
}
synced=no
if [ "$NODE" = new ] && ! systemctl --user is-active --quiet $NODE_UNIT; then
	echo "node: NOT running (see: journalctl --user -u $NODE_UNIT)"
elif ! out=\$(rpc getblockchaininfo); then
	if [ "$NODE" = new ]; then echo "node: starting up"; else echo "node: cannot reach your node at $RPC_URL"; fi
else
	python3 -c 'import json,sys; j=json.loads(sys.argv[1]); print("node: getting the list of blocks from other nodes, miners cannot connect yet" if j["headers"] == 0 else "node: %s, block %d of %d, %.1f%% checked" % ("still syncing, miners cannot connect yet" if j["initialblockdownload"] else "synced", j["blocks"], j["headers"], 100*j["verificationprogress"]))' "\$out"
	python3 -c 'import json,sys; sys.exit(1 if json.loads(sys.argv[1])["initialblockdownload"] else 0)' "\$out" && synced=yes
	echo "connected to \$(rpc getconnectioncount) other nodes"
fi
if systemctl --user is-active --quiet $GW_UNIT; then echo "gateway: running, dashboard at $(dashboard_url)"; else echo "gateway: NOT running"; fi
echo "payout address: $ADDRESS"
$( [ "$MODE" = pool ] && [ -z "$POOL_HOST" ] && echo "echo \"your CONVOY stats: https://convoy.xyz/stats/$ADDRESS\"" )
$( [ "$SHARED" = yes ] && echo "echo \"shared: each miner is paid to the address in its username; check them on the miners page\"" )
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
		if [ "$DASH_OPEN" = network ] && [ -n "$LAN_CIDR" ]; then
			echo "sudo firewall-cmd --permanent --add-rich-rule='rule family=\"ipv4\" source address=\"$LAN_CIDR\" port port=\"$API_PORT\" protocol=\"tcp\" accept'"
		fi
		echo "sudo firewall-cmd --reload"
	else
		echo "${UFW_INSTALL:-# install ufw with your package manager}"
		echo "sudo ufw allow ssh"
		echo "sudo ufw allow 8333/tcp"
		[ ${#MINER_IPS[@]} -gt 0 ] || echo "sudo ufw allow $STRATUM_PORT/tcp"
		for ip in "${MINER_IPS[@]}"; do echo "sudo ufw allow from $ip to any port $STRATUM_PORT proto tcp"; done
		if [ "$DASH_OPEN" = network ] && [ -n "$LAN_CIDR" ]; then echo "sudo ufw allow from $LAN_CIDR to any port $API_PORT proto tcp"; fi
		echo "sudo ufw enable"
	fi
}
