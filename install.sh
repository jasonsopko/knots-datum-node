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
# [--shared yes|no] [--node new | --node <host[:port]> --rpc-user <user>,
# with the password in the NODE_RPC_PASSWORD environment variable, to use a
# node you already run] [--software plumb|knots, for a new node: Plumb unless
# this node already runs Knots]
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
		--software) [ $# -ge 2 ] || die "--software needs a value"; check_software "$2" >/dev/null || die "--software must be plumb or knots"; F_SOFTWARE=$2; shift 2 ;;
		-h|--help) sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
# dbcache: about a quarter of RAM, 450 MB floor, 4000 MB ceiling
DBCACHE=$(( MEM_MB / 4 )); [ $DBCACHE -lt 450 ] && DBCACHE=450; [ $DBCACHE -gt 4000 ] && DBCACHE=4000

# What an administrator has to do first. Collect everything missing and print
# it at once, so nobody has to go back and forth.
MISSING=()
missing_pkgs=0
for c in "${COMMANDS[@]}"; do command -v "$c" >/dev/null 2>&1 || missing_pkgs=1; done
command -v pkg-config >/dev/null 2>&1 && { pkg-config --exists "${LIBS[@]}" || missing_pkgs=1; }
[ $missing_pkgs = 0 ] || MISSING+=("$PKG_INSTALL")
[ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" = yes ] || MISSING+=("sudo loginctl enable-linger $(id -un)")
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
CHOOSE_SOFTWARE=1
settle_settings
[ "$NODE" != new ] || TARBALL=bitcoin-$NODE_VER-$ARCH.tar.gz
echo
show_settings

if [ "$NODE" = new ]; then
	# uname -m names the kernel's architecture, and a 64-bit kernel can run a
	# 32-bit system (the 32-bit Raspberry Pi OS boots one on a Pi 4 or 5). The
	# node release this installs is the 64-bit one.
	[ "$(getconf LONG_BIT 2>/dev/null)" = 64 ] || { [ $DRY_RUN = 1 ] && echo "warning: this computer runs a 32-bit operating system, and a new node needs a 64-bit one"; } || die "this computer runs a 32-bit operating system on a 64-bit processor, and the node release this installs needs a 64-bit one. Install the 64-bit version of the operating system (on a Raspberry Pi: Raspberry Pi OS 64-bit), or use a node you already run."
	[ "$MEM_MB" -ge 1800 ] || { [ $DRY_RUN = 1 ] && echo "warning: a new node needs at least 2 GB of RAM (this has ${MEM_MB} MB)"; } || die "a new node needs at least 2 GB of RAM (this computer has ${MEM_MB} MB). Use an existing node, or a bigger computer."
	[ "$DISK_GB" -ge 40 ] || { [ $DRY_RUN = 1 ] && echo "warning: a new node needs at least 40 GB free disk (this has ${DISK_GB} GB)"; } || die "a new node needs at least 40 GB free in your home directory (it has ${DISK_GB} GB)."
	echo
	echo "Note: after this finishes, the node downloads and checks the whole chain"
	echo "before miners can connect. That takes a day or more and about 800 GB of"
	echo "internet data. It deletes old blocks as it goes, so it needs far less disk."
fi

if [ $DRY_RUN = 1 ]; then
	PW='<random password, generated at install>'
	cat <<EOF

DRY RUN: nothing below has been done. A real run does this, in order, as
user $(id -un), without root.

== 1. download the node
EOF
	if [ "$NODE" = new ]; then cat <<EOF
$NODE_NAME $NODE_VER, from:
$NODE_BASE/SHA256SUMS
$NODE_BASE/SHA256SUMS.asc
$NODE_BASE/$TARBALL
Stops unless SHA256SUMS.asc is a valid signature by
$NODE_FPR ($NODE_SIGNER)
and the download matches its line in SHA256SUMS. Puts bitcoind and
bitcoin-cli in $BIN.
EOF
	else echo "Skipped: the gateway uses your node at $NODE_HOST:$NODE_PORT."; fi
	cat <<EOF

== 2. build the DATUM gateway
git fetch $GW_REPO $GW_COMMIT
(CONVOY master plus the fix from CONVOYMining/datum_gateway#18)
Builds it and puts datum_gateway in $BIN.

== 3. $CONF/bitcoin.conf (readable by you only)
$(if [ "$NODE" = new ]; then render_bitcoin_conf "gateway:<salt>\$<HMAC-SHA256 of the password below>"; else echo "Your node has its own. It needs these lines for the gateway's login (a real"; echo "run makes the password and prints them with it):"; echo; node_conf_lines "$EXT_RPC_USER:<salt>\$<HMAC-SHA256 of the login password>"; fi)

== 4. $CONF/datum_gateway.json (readable by you only)
$(render_gateway_json "$( [ "$NODE" = new ] && echo "$PW" || echo "<the node login password>")" "$PW")

== 5. $UNITS/$NODE_UNIT
$(if [ "$NODE" = new ]; then render_node_unit; else echo "Skipped: your node runs on its own."; fi)

== 6. $UNITS/$GW_UNIT
$(render_gateway_unit)

== 7. $BASE/status
$(render_status_script)

Also copies configure.sh and lib.sh to $BASE/configure and
$BASE/lib.sh, for changing settings later.

== 8. start the services (systemctl --user enable --now)
EOF
	echo
	echo "== 9. firewall commands it prints, for an administrator to run if this"
	echo "computer has a firewall turned on"
	firewall_commands
	exit 0
fi

mkdir -p "$BIN" "$GW_STATE" "$CONF" "$UNITS"
[ "$NODE" = existing ] || mkdir -p "$DATA"
chmod 700 "$BASE" "$CONF"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

cd "$WORK"
if [ "$NODE" = new ]; then
say "downloading $NODE_NAME $NODE_VER"
# -L: GitHub serves release files through a redirect.
curl -sSfLO "$NODE_BASE/SHA256SUMS"
curl -sSfLO "$NODE_BASE/SHA256SUMS.asc"
curl -sSfLO "$NODE_BASE/$TARBALL"
# The keys go into a staging keyring first, and only an export of it that
# drops every subkey carrying the release key's fingerprint reaches the
# keyring the signature is checked with. Someone holding a stolen release key
# can attach it as a subkey to a certificate of their own; served ahead of
# the real key, that makes gpg check through their certificate, or keep an
# unrevoked copy of the real key beside the revoked one.
export GNUPGHOME=$WORK/gnupg; mkdir -m 700 "$GNUPGHOME" "$WORK/stage"
curl -sSfL "$NODE_KEY_URL" | GNUPGHOME=$WORK/stage gpg -q --import 2>/dev/null || true
GNUPGHOME=$WORK/stage gpg -q --keyserver hkps://keys.openpgp.org --recv-keys "$NODE_FPR" 2>/dev/null || true
GNUPGHOME=$WORK/stage gpg --export --export-filter "drop-subkey=fpr = $NODE_FPR" 2>/dev/null | gpg -q --import 2>/dev/null || true
GNUPGHOME=$WORK/stage gpgconf --kill all 2>/dev/null || true
# Only a signature by this exact key counts, as its own primary key (VALIDSIG's
# first and last fingerprints), and not once that key is revoked. gpg still
# prints VALIDSIG for a revoked key; the signature line says REVKEYSIG, or
# EXPKEYSIG once the key has also expired, so ask gpg about the key itself
# too: exactly one pub whose own fingerprint is this one, not revoked. An
# expired key still counts.
VERIFY=$(gpg --status-fd 1 --verify SHA256SUMS.asc SHA256SUMS 2>/dev/null || true)
grep -q "^\[GNUPG:\] VALIDSIG $NODE_FPR .* $NODE_FPR\$" <<<"$VERIFY" || die "SHA256SUMS is not signed by $NODE_FPR"
grep -qE "^\[GNUPG:\] (GOODSIG|EXPKEYSIG) (${NODE_FPR: -16}|$NODE_FPR) " <<<"$VERIFY" || die "SHA256SUMS is signed by $NODE_FPR, but gpg does not call the signature good"
[ "$(gpg --with-colons --list-keys "$NODE_FPR" 2>/dev/null | awk -F: -v f="$NODE_FPR" '$1 == "pub" {v = $2; p = 1; next} p && $1 == "fpr" {if ($10 == f) {n++; if (v == "r") r = 1}; p = 0} END {print (n == 1 && !r) ? "ok" : "no"}')" = ok ] || die "SHA256SUMS is signed by $NODE_FPR, but gpg lists that key as revoked, or more than once"
gpgconf --kill all 2>/dev/null || true
echo "SHA256SUMS signed by $NODE_FPR ($NODE_SIGNER)"
grep " $TARBALL\$" SHA256SUMS | sha256sum -c - || die "download does not match SHA256SUMS"
tar xzf "$TARBALL"
install -m 755 "bitcoin-$NODE_VER/bin/bitcoind" "bitcoin-$NODE_VER/bin/bitcoin-cli" "$BIN/"
# The work dir as datadir, so this neither reads nor writes ~/.bitcoin.
"$BIN/bitcoind" -datadir="$WORK" -version | sed -n 1p
fi

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
if [ "$NODE" = new ]; then
	# The gateway's login to the node, kept across reinstalls so the two always
	# agree. bitcoin.conf is rewritten around it, which brings in any new
	# settings.
	OLD_AUTH=
	[ ! -f "$CONF/bitcoin.conf" ] || OLD_AUTH=$(sed -n 's/^rpcauth=//p' "$CONF/bitcoin.conf" | head -1)
	if [ -n "$RPC_PASS" ] && [ -n "$OLD_AUTH" ]; then
		RPC_AUTH=$OLD_AUTH
	else
		RPC_PASS=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
		RPC_AUTH=$(new_rpcauth gateway "$RPC_PASS")
	fi
	(umask 077; render_bitcoin_conf "$RPC_AUTH" > "$CONF/bitcoin.conf")
else
	rm -f "$CONF/bitcoin.conf"
	if [ -f "$UNITS/$NODE_UNIT" ]; then
		echo "stopping the node this installed earlier; its data stays in $DATA"
		user_systemctl disable --now "$NODE_UNIT" 2>/dev/null || true
		rm -f "$UNITS/$NODE_UNIT"
	fi
fi
(umask 077; render_gateway_json "$RPC_PASS" "$DASH_PASS" > "$CONF/datum_gateway.json")
install -m 755 "$SRC_DIR/configure.sh" "$BASE/configure"
install -m 644 "$SRC_DIR/lib.sh" "$BASE/lib.sh"

say "starting"
UNITS_TO_START=("$GW_UNIT")
if [ "$NODE" = new ]; then render_node_unit > "$UNITS/$NODE_UNIT"; UNITS_TO_START=("$NODE_UNIT" "$GW_UNIT"); fi
render_gateway_unit > "$UNITS/$GW_UNIT"
render_status_script > "$BASE/status"
chmod 755 "$BASE/status"
user_systemctl daemon-reload
user_systemctl enable -q "${UNITS_TO_START[@]}"
user_systemctl restart "${UNITS_TO_START[@]}"
sleep 3
user_systemctl is-active --quiet "$GW_UNIT" || die "the gateway did not start; see: journalctl --user -u $GW_UNIT"

if [ "$NODE" = new ]; then
	cat <<EOF

Done. Your node is now downloading and checking the whole chain. That takes
a day or more. To see how far along it is:
EOF
else
	cat <<EOF

Done. The gateway is using your node at $NODE_HOST:$NODE_PORT. To check on
both:
EOF
fi
cat <<EOF

    ~/knots-datum-node/status

When it says "synced", point your miners at:

$(miner_login_help)

To change your node, payout address, pool, name or dashboard later:

    ~/knots-datum-node/configure

EOF
dashboard_help
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
