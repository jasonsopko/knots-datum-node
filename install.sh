#!/bin/bash
# SPDX-License-Identifier: MIT
# Set up your own Bitcoin Knots node and DATUM gateway, running as an ordinary
# user (not root), so the block templates your miners work on come from your
# own node.
#
# Usage, as the user that will run the node (not root):
#   ./install.sh               asks for your payout address and settings
#   ./install.sh --dry-run     shows everything it would do, changes nothing
#   ./install.sh --uninstall
#
# To change settings later:  ~/knots-datum-node/configure
#
# Settings can also be given as flags, which skips the questions when there is
# no terminal: --address <address> --mode pool|solo [--tag <your name>]
# [--primary-tag <name>] [--pool-host <host[:port]> --pool-pubkey <hex>]
#
# The mining port is open to anyone by default, like a pool's.
# --miner-ip <IP or range> (repeatable) prints firewall commands that limit it
# to your own miners.
#
# Works on Linux distributions that use systemd and glibc: Debian, Ubuntu,
# Fedora, RHEL and its rebuilds, Arch, openSUSE, and their derivatives. Not on
# Alpine (musl) or distributions without systemd.
set -euo pipefail
SRC_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
. "$SRC_DIR/lib.sh"

DRY_RUN=0 UNINSTALL=0 NO_PROMPT=0
while [ $# -gt 0 ]; do
	if parse_setting_flag "$@"; then shift "$SHIFT"; continue; fi
	case "$1" in
		--miner-ip) [ $# -ge 2 ] || die "--miner-ip needs a value"; MINER_IPS+=("$2"); shift 2 ;;
		--dry-run) DRY_RUN=1; shift ;;
		--uninstall) UNINSTALL=1; shift ;;
		--no-prompt) NO_PROMPT=1; shift ;;
		-h|--help) sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) die "unknown option $1 (see ./install.sh --help)" ;;
	esac
done

[ "$(id -u)" != 0 ] || die "do not run this as root. Log in as the user that will run the node (see the README) and run it again."
require_python

if [ $UNINSTALL = 1 ]; then
	say "removing the node and gateway services"
	user_systemctl disable --now "$GW_UNIT" "$NODE_UNIT" 2>/dev/null || true
	rm -f "$UNITS/$GW_UNIT" "$UNITS/$NODE_UNIT"
	user_systemctl daemon-reload 2>/dev/null || true
	rm -rf "$BIN" "$CONF" "$GW_STATE" "$BASE/status" "$BASE/configure" "$BASE/lib.sh"
	echo "Stopped and removed. The chain data is still in $DATA"
	echo "(it saves a day of syncing if you install again). To delete it:"
	echo "    rm -rf $BASE"
	exit 0
fi

[ ! -e "$BASE/.git" ] || die "$BASE is a copy of this installer, and the node installs into that same folder. Move it (for example: mv $BASE ~/installer), then run ./install.sh from there."
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
OWN_IP=$(ip -4 route get 192.0.2.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')

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
if [ ${#MISSING[@]} -gt 0 ]; then
	echo
	echo "Before this can run, someone with admin rights needs to run:"
	echo
	printf '    %s\n' "${MISSING[@]}"
	echo
	[ $DRY_RUN = 1 ] && echo "(dry run continues below to show the rest)" || exit 1
fi

say "your settings"
load_saved_settings
settle_settings
echo
show_settings

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

Also copies configure.sh and lib.sh to $BASE/configure and
$BASE/lib.sh, for changing settings later.

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
# The gateway's login to the node. Kept across reinstalls, so the node and the
# gateway always agree on it.
if [ -f "$CONF/bitcoin.conf" ] && [ -n "$S_RPC_PASS" ]; then
	RPC_PASS=$S_RPC_PASS
	echo "keeping the node configuration in $CONF"
else
	RPC_PASS=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
	RPC_AUTH=$(python3 -c 'import hmac,secrets,sys; s=secrets.token_hex(16); print("gateway:%s$%s" % (s, hmac.new(s.encode(), sys.argv[1].encode(), "sha256").hexdigest()))' "$RPC_PASS")
	(umask 077; render_bitcoin_conf "$RPC_AUTH" > "$CONF/bitcoin.conf")
fi
API_PASS=${S_API_PASS:-$(python3 -c 'import secrets; print(secrets.token_urlsafe(16))')}
(umask 077; render_gateway_json "$RPC_PASS" "$API_PASS" > "$CONF/datum_gateway.json")
install -m 755 "$SRC_DIR/configure.sh" "$BASE/configure"
install -m 644 "$SRC_DIR/lib.sh" "$BASE/lib.sh"

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

To change your payout address, pool or name later:

    ~/knots-datum-node/configure
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
