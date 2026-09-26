#!/bin/bash
# SPDX-License-Identifier: MIT
# Set up your own Bitcoin Knots node and DATUM gateway, running as an ordinary
# user (not root), so the block templates your miners work on come from your
# own node.
#
# Usage, as the user that will run the node (not root):
#   ./install.sh --address <payout address> --mode pool|solo [--tag <text>]
#                [--miner-ip <IP or range your miners connect from>] ...
#                [--pool-host <host[:port]> --pool-pubkey <hex>]
#                [--dry-run]
#   ./install.sh --uninstall
#
# --dry-run prints everything the install would do and every file it would
# write, then exits without changing anything.
#
# The mining port is open to anyone by default, like a pool's. --miner-ip
# prints firewall commands that limit it to your own miners.
#
# The script needs a few things set up by an administrator first. It checks
# for them and prints the exact commands if anything is missing.
#
# Works on Linux distributions that use systemd and glibc: Debian, Ubuntu,
# Fedora, RHEL and its rebuilds, Arch, openSUSE, and their derivatives. Not on
# Alpine (musl) or distributions without systemd.
set -euo pipefail

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

HOME_DIR=${HOME:?}
BASE=$HOME_DIR/knots-datum-node
BIN=$BASE/bin
DATA=$BASE/bitcoin
GW_STATE=$BASE/gateway
CONF=$BASE/conf
UNITS=$HOME_DIR/.config/systemd/user
NODE_UNIT=knots-datum-node-bitcoind.service
GW_UNIT=knots-datum-node-gateway.service

ADDRESS= MODE= TAG= FORCE=0 POOL_HOST= POOL_PORT= POOL_PUBKEY= DRY_RUN=0 UNINSTALL=0
MINER_IPS=()

die() { echo; echo "error: $*" >&2; exit 1; }

# The one line an administrator runs to install what the script needs.
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
say() { echo; echo "== $*"; }

while [ $# -gt 0 ]; do
	case "$1" in
		--address) ADDRESS=$2; shift 2 ;;
		--miner-ip) MINER_IPS+=("$2"); shift 2 ;;
		--mode) MODE=$2; shift 2 ;;
		--tag) TAG=$2; shift 2 ;;
		--pool-host) POOL_HOST=$2; shift 2 ;;
		--pool-pubkey) POOL_PUBKEY=$2; shift 2 ;;
		--force-config) FORCE=1; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		--uninstall) UNINSTALL=1; shift ;;
		-h|--help) sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) die "unknown option $1 (see ./install.sh --help)" ;;
	esac
done

[ "$(id -u)" != 0 ] || die "do not run this as root. Log in as the user that will run the node (see the README) and run it again."
command -v python3 >/dev/null 2>&1 || { echo; echo "Before this can run, someone with admin rights needs to run:"; echo; echo "    $PKG_INSTALL"; exit 1; }
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
user_systemctl() { systemctl --user "$@"; }

if [ $UNINSTALL = 1 ]; then
	say "removing the node and gateway services"
	user_systemctl disable --now "$GW_UNIT" "$NODE_UNIT" 2>/dev/null || true
	rm -f "$UNITS/$GW_UNIT" "$UNITS/$NODE_UNIT"
	user_systemctl daemon-reload 2>/dev/null || true
	rm -rf "$BIN" "$CONF" "$GW_STATE" "$BASE/status"
	echo "Stopped and removed. The chain data is still in $DATA"
	echo "(it saves a day of syncing if you install again). To delete it:"
	echo "    rm -rf $BASE"
	exit 0
fi

[ ! -e "$BASE/.git" ] || die "$BASE is a copy of this installer, and the node installs into that same folder. Move it (for example: mv $BASE ~/installer), then run ./install.sh from there."
[ -n "$ADDRESS" ] || die "--address is required (the Bitcoin address your rewards go to)"
case "$MODE" in pool|solo) ;; *) die "--mode must be pool or solo" ;; esac
if [ -n "$POOL_HOST$POOL_PUBKEY" ]; then
	[ "$MODE" = pool ] || die "--pool-host and --pool-pubkey only apply to --mode pool"
	[ -n "$POOL_HOST" ] && [ -n "$POOL_PUBKEY" ] || die "--pool-host and --pool-pubkey go together"
	[[ "$POOL_HOST" =~ ^[A-Za-z0-9.-]{1,253}(:[0-9]{1,5})?$ ]] || die "--pool-host must be a host name or IP, optionally with :port"
	[[ "$POOL_PUBKEY" =~ ^[0-9a-f]{128}$ ]] || die "--pool-pubkey must be 128 lowercase hex characters"
	POOL_PORT=28915
	if [[ "$POOL_HOST" == *:* ]]; then POOL_PORT=${POOL_HOST##*:}; POOL_HOST=${POOL_HOST%:*}; fi
	[ "$POOL_PORT" -ge 1 ] && [ "$POOL_PORT" -le 65535 ] || die "--pool-host port out of range"
fi
[ "$ADDRESS" != YOUR-ADDRESS ] || die "replace YOUR-ADDRESS with your own Bitcoin address, the one your mining rewards should go to (it starts with bc1, 1 or 3)"
[[ "$ADDRESS" =~ ^(bc1[02-9ac-hj-np-z]{11,87}|[13][1-9A-HJ-NP-Za-km-z]{25,34})$ ]] || die "$ADDRESS does not look like a Bitcoin address. Use the address your mining rewards should go to; it starts with bc1, 1 or 3."
[[ "$TAG" =~ ^[[:print:]]{0,40}$ ]] && [[ "$TAG" != *'"'* ]] && [[ "$TAG" != *'\'* ]] || die "--tag: 40 printable characters, no quotes or backslashes"
for ip in "${MINER_IPS[@]}"; do
	python3 -c 'import ipaddress,sys; ipaddress.ip_network(sys.argv[1], strict=False)' "$ip" 2>/dev/null || die "--miner-ip $ip is not an IP address or range"
	[ "$ip" != 0.0.0.0/0 ] && [ "$ip" != ::/0 ] || die "--miner-ip must not be the whole internet"
done

say "checking this computer"
. /etc/os-release
echo "${PRETTY_NAME:-unknown Linux}"
PLATFORM_OK=1
getconf GNU_LIBC_VERSION >/dev/null 2>&1 || { PLATFORM_OK=0; echo "this system does not use glibc (Alpine and other musl systems cannot run the Knots release)"; }
[ -d /run/systemd/system ] || { PLATFORM_OK=0; echo "this system is not running systemd, which the node and gateway services need"; }
if [ $PLATFORM_OK = 0 ]; then
	[ $DRY_RUN = 1 ] && echo "(dry run continues, but a real install will stop here)" || die "unsupported system, see above"
fi
case "$(uname -m)" in
	x86_64) ARCH=x86_64-linux-gnu ;;
	aarch64) ARCH=aarch64-linux-gnu ;;
	*) die "unsupported CPU $(uname -m)" ;;
esac
MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
DISK_GB=$(df -BG --output=avail "$HOME_DIR" | tail -1 | tr -dc 0-9)
echo "user $(id -un), RAM ${MEM_MB} MB, free disk ${DISK_GB} GB, $(nproc) CPUs"
echo "Note: after this finishes, the node downloads and checks the whole chain"
echo "before miners can connect. That takes most of a day and about 800 GB of"
echo "internet data. It deletes old blocks as it goes, so it needs far less disk."
# dbcache: about a quarter of RAM, 450 MB floor, 4000 MB ceiling
DBCACHE=$(( MEM_MB / 4 )); [ $DBCACHE -lt 450 ] && DBCACHE=450; [ $DBCACHE -gt 4000 ] && DBCACHE=4000
TARBALL=bitcoin-$KNOTS_VER-$ARCH.tar.gz

# What an administrator has to do first. Collect everything missing and print
# it at once, so nobody has to go back and forth.
MISSING=()
missing_pkgs=0
for c in "${COMMANDS[@]}"; do command -v "$c" >/dev/null 2>&1 || missing_pkgs=1; done
command -v pkg-config >/dev/null 2>&1 && { pkg-config --exists "${LIBS[@]}" || missing_pkgs=1; }
[ $missing_pkgs = 0 ] || MISSING+=("$PKG_INSTALL")
[ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" = yes ] || MISSING+=("sudo loginctl enable-linger $(id -un)")
[ "$MEM_MB" -ge 1800 ] || MISSING+=("# this computer needs at least 2 GB of RAM (it has ${MEM_MB} MB)")
[ "$DISK_GB" -ge 40 ] || MISSING+=("# this user's home directory needs at least 40 GB free (it has ${DISK_GB} GB)")

OWN_IP=$(ip -4 route get 192.0.2.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')

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

# Everything the install writes comes from the functions below, so --dry-run
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
    "coinbase_tag_primary": "DATUM",
    "coinbase_tag_secondary": "$TAG",
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

if [ ${#MISSING[@]} -gt 0 ]; then
	echo
	echo "Before this can run, someone with admin rights needs to run:"
	echo
	printf '    %s\n' "${MISSING[@]}"
	echo
	[ $DRY_RUN = 1 ] && echo "(dry run continues below to show the rest)" || exit 1
fi

if [ $DRY_RUN = 1 ]; then
	PW='<random password, generated at install>'
	cat <<EOF

DRY RUN: nothing below has been done. A real run does this, in order, as
user $(id -un), without root.

== 1. download Bitcoin Knots $KNOTS_VER
$KNOTS_BASE/SHA256SUMS
$KNOTS_BASE/SHA256SUMS.asc
$KNOTS_BASE/$TARBALL
Stops unless SHA256SUMS.asc is a valid signature by
$KNOTS_FPR (Luke Dashjr, Knots release key) and the download matches its
line in SHA256SUMS. Puts bitcoind and bitcoin-cli in $BIN.

== 2. build the DATUM gateway
git fetch $GW_REPO $GW_COMMIT
(CONVOY master plus the fix from CONVOYMining/datum_gateway#18)
Builds it and puts datum_gateway in $BIN.

== 3. $CONF/bitcoin.conf (readable by you only)
$(render_bitcoin_conf "gateway:<salt>\$<HMAC-SHA256 of the password below>")

== 4. $CONF/datum_gateway.json (readable by you only)
$(render_gateway_json "$PW" "$PW")

== 5. $UNITS/$NODE_UNIT
$(render_node_unit)

== 6. $UNITS/$GW_UNIT
$(render_gateway_unit)

== 7. $BASE/status
$(render_status_script)

== 8. start both services (systemctl --user enable --now)
EOF
	echo
	echo "== 9. firewall commands it prints, for an administrator to run if this"
	echo "computer has a firewall turned on"
	firewall_commands
	exit 0
fi

mkdir -p "$BIN" "$DATA" "$GW_STATE" "$CONF" "$UNITS"
chmod 700 "$BASE" "$CONF"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

say "downloading Bitcoin Knots $KNOTS_VER"
cd "$WORK"
curl -sSfO "$KNOTS_BASE/SHA256SUMS"
curl -sSfO "$KNOTS_BASE/SHA256SUMS.asc"
curl -sSfO "$KNOTS_BASE/$TARBALL"
export GNUPGHOME=$WORK/gnupg; mkdir -m 700 "$GNUPGHOME"
curl -sSf "$KNOTS_KEY_URL" | gpg -q --import 2>/dev/null || true
gpg -q --keyserver hkps://keys.openpgp.org --recv-keys "$KNOTS_FPR" 2>/dev/null || true
# Only a signature by this exact key counts, wherever the key came from.
VERIFY=$(gpg --status-fd 1 --verify SHA256SUMS.asc SHA256SUMS 2>/dev/null || true)
grep -q "^\[GNUPG:\] VALIDSIG $KNOTS_FPR " <<<"$VERIFY" || die "SHA256SUMS is not signed by $KNOTS_FPR"
echo "SHA256SUMS signed by $KNOTS_FPR"
grep " $TARBALL\$" SHA256SUMS | sha256sum -c - || die "download does not match SHA256SUMS"
tar xzf "$TARBALL"
install -m 755 "bitcoin-$KNOTS_VER/bin/bitcoind" "bitcoin-$KNOTS_VER/bin/bitcoin-cli" "$BIN/"
"$BIN/bitcoind" -version | head -1

say "building the DATUM gateway at $GW_COMMIT"
git init -q gw && cd gw
git fetch -q --depth 1 "$GW_REPO" "$GW_COMMIT"
[ "$(git rev-parse FETCH_HEAD)" = "$GW_COMMIT" ] || die "fetched $(git rev-parse FETCH_HEAD), expected $GW_COMMIT"
git checkout -q "$GW_COMMIT"
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build build -j"$(nproc)" >/dev/null
install -m 755 build/datum_gateway "$BIN/datum_gateway"
cd "$WORK"

say "writing configuration"
if [ -f "$CONF/bitcoin.conf" ] && [ $FORCE = 0 ]; then
	echo "keeping the existing configuration in $CONF (add --force-config to rewrite it)"
else
	RPC_PASS=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
	RPC_AUTH=$(python3 -c 'import hmac,secrets,sys; s=secrets.token_hex(16); print("gateway:%s$%s" % (s, hmac.new(s.encode(), sys.argv[1].encode(), "sha256").hexdigest()))' "$RPC_PASS")
	API_PASS=$(python3 -c 'import secrets; print(secrets.token_urlsafe(16))')
	(umask 077; render_bitcoin_conf "$RPC_AUTH" > "$CONF/bitcoin.conf")
	(umask 077; render_gateway_json "$RPC_PASS" "$API_PASS" > "$CONF/datum_gateway.json")
fi

say "starting"
render_node_unit > "$UNITS/$NODE_UNIT"
render_gateway_unit > "$UNITS/$GW_UNIT"
render_status_script > "$BASE/status"
chmod 755 "$BASE/status"
user_systemctl daemon-reload
user_systemctl enable -q "$NODE_UNIT" "$GW_UNIT"
user_systemctl restart "$NODE_UNIT" "$GW_UNIT"
sleep 3
user_systemctl is-active --quiet "$GW_UNIT" || die "the gateway did not start; see: journalctl --user -u $GW_UNIT"

SHOW_IP=${OWN_IP:-"<this computer's IP>"}
cat <<EOF

Done. Your node is now downloading and checking the whole chain. That takes
most of a day. To see how far along it is:

    ~/knots-datum-node/status

When it says "synced", point your miners at:

    stratum+tcp://$SHOW_IP:$STRATUM_PORT
    username: any name for the miner   password: x
EOF
if [ ${#MINER_IPS[@]} -gt 0 ]; then
	FW_TEXT="have an administrator run these, so only ${MINER_IPS[*]} can
reach the mining port. Until then it is open to anyone who finds it."
else
	FW_TEXT="if this computer has a firewall turned on, an administrator needs to
open the mining port with these commands. At home behind a router, miners on
your own network do not need this."
fi
cat <<EOF

Firewall: $FW_TEXT

EOF
firewall_commands | sed 's/^/    /'
cat <<EOF

To remove everything later:  ./install.sh --uninstall
EOF
