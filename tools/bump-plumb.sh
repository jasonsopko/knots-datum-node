#!/bin/bash
# SPDX-License-Identifier: MIT
# For maintainers: point the installer at a new Plumb release.
#
#   tools/bump-plumb.sh <version>      for example 29.4.2.knots20260508.plumb7
#
# Downloads that release's SHA256SUMS and SHA256SUMS.asc and stops unless the
# signature is by PLUMB_FPR, a key gpg does not list as revoked, as install.sh
# checks it. Then it downloads the x86_64 and the aarch64 tarball, since the
# installer takes whichever matches the machine, and stops unless each matches
# its line and holds bitcoind and bitcoin-cli, and unless the two binaries for
# this machine's own architecture report that version. Then it rewrites the
# version in lib.sh, README.md and INSTALL.md, all three or none, and shows
# the diff. It commits nothing. Run ./install.sh --dry-run after.
#
# PLUMB_BASE_URL replaces the release download URL, for testing against local
# copies (file:///...).
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."
die() { echo "error: $*" >&2; exit 1; }
NEW=${1:-}
[[ "$NEW" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?\.knots[0-9]{8}\.plumb[0-9]+$ ]] || die "usage: tools/bump-plumb.sh <version>, for example 29.4.2.knots20260508.plumb7"
OLD=$(sed -n 's/^PLUMB_VER=//p' lib.sh)
FPR=$(sed -n 's/^PLUMB_FPR=\([0-9A-F]\{40\}\).*/\1/p' lib.sh)
KEY_URL=$(sed -n 's/^PLUMB_KEY_URL=//p' lib.sh)
KNOTS_VER=$(sed -n 's/^KNOTS_VER=//p' lib.sh)
BASE_PATTERN=$(sed -n 's/^PLUMB_BASE=//p' lib.sh)
[ -n "$OLD" ] && [ -n "$FPR" ] && [ -n "$KEY_URL" ] && [[ "$BASE_PATTERN" == *'$PLUMB_VER'* ]] || die "lib.sh does not have PLUMB_VER, PLUMB_FPR, PLUMB_KEY_URL and a PLUMB_BASE that uses \$PLUMB_VER"
[ "$NEW" != "$OLD" ] || die "the installer already uses $NEW"
BASE=${BASE_PATTERN//'$PLUMB_VER'/$NEW}
if [ -n "${PLUMB_BASE_URL:-}" ]; then BASE=$PLUMB_BASE_URL; echo "PLUMB_BASE_URL is set: downloading from $BASE, not GitHub"; fi
case "$(uname -m)" in x86_64|aarch64) MINE=$(uname -m) ;; *) die "run this on an x86_64 or aarch64 machine" ;; esac

# A keyring of its own, set before the trap, so the trap never touches yours.
W=$(mktemp -d); export GNUPGHOME=$W/gnupg; mkdir -m 700 "$GNUPGHOME" "$W/stage"
trap 'GNUPGHOME=$W/stage gpgconf --kill all 2>/dev/null || true; gpgconf --kill all 2>/dev/null || true; rm -rf "$W"' EXIT
cd "$W"
echo "== downloading Plumb $NEW"
for f in SHA256SUMS SHA256SUMS.asc; do
	curl -sSfLO "$BASE/$f" || die "could not download $BASE/$f (is the release published?)"
done
# As install.sh does: a staging keyring, then only an export of it that drops
# every subkey carrying the release key's fingerprint.
curl -sSfL "$KEY_URL" | GNUPGHOME=$W/stage gpg -q --import 2>/dev/null || true
GNUPGHOME=$W/stage gpg -q --keyserver hkps://keys.openpgp.org --recv-keys "$FPR" 2>/dev/null || true
GNUPGHOME=$W/stage gpg --export --export-filter "drop-subkey=fpr = $FPR" 2>/dev/null | gpg -q --import 2>/dev/null || true
VERIFY=$(gpg --status-fd 1 --verify SHA256SUMS.asc SHA256SUMS 2>/dev/null || true)
# The pinned key as its own primary key: VALIDSIG's first and last fingerprints.
grep -q "^\[GNUPG:\] VALIDSIG $FPR .* $FPR\$" <<<"$VERIFY" || die "SHA256SUMS is not signed by $FPR"
grep -qE "^\[GNUPG:\] (GOODSIG|EXPKEYSIG) (${FPR: -16}|$FPR) " <<<"$VERIFY" || die "SHA256SUMS is signed by $FPR, but gpg does not call the signature good"
# A revoked key that has also expired shows EXPKEYSIG, so ask about the key too:
# exactly one pub whose own fingerprint is this one, not revoked.
[ "$(gpg --with-colons --list-keys "$FPR" 2>/dev/null | awk -F: -v f="$FPR" '$1 == "pub" {v = $2; p = 1; next} p && $1 == "fpr" {if ($10 == f) {n++; if (v == "r") r = 1}; p = 0} END {print (n == 1 && !r) ? "ok" : "no"}')" = ok ] || die "SHA256SUMS is signed by $FPR, but gpg lists that key as revoked, or more than once"
echo "SHA256SUMS signed by $FPR"
for a in x86_64 aarch64; do
	t=bitcoin-$NEW-$a-linux-gnu.tar.gz
	curl -sSfLO "$BASE/$t" || die "could not download $BASE/$t (the installer needs both the x86_64 and the aarch64 tarball)"
	grep " $t\$" SHA256SUMS | sha256sum -c - || die "$t does not match SHA256SUMS"
	tar tzf "$t" > "$t.list"
	grep -qx "bitcoin-$NEW/bin/bitcoind" "$t.list" && grep -qx "bitcoin-$NEW/bin/bitcoin-cli" "$t.list" || die "$t has no bitcoin-$NEW/bin/bitcoind and bitcoin-cli"
done
tar xzf "bitcoin-$NEW-$MINE-linux-gnu.tar.gz"
mkdir d
[ -x "./bitcoin-$NEW/bin/bitcoind" ] && [ -x "./bitcoin-$NEW/bin/bitcoin-cli" ] || die "the tarball has no bitcoin-$NEW/bin/bitcoind and bitcoin-cli"
V=$("./bitcoin-$NEW/bin/bitcoind" -datadir="$W/d" -version | sed -n 1p)
[ "$V" = "Bitcoin Knots daemon version v$NEW" ] || die "the tarball's bitcoind says \"$V\", not v$NEW"
echo "$V"
V=$("./bitcoin-$NEW/bin/bitcoin-cli" -datadir="$W/d" -version | sed -n 1p)
[ "$V" = "Bitcoin Knots RPC client version v$NEW" ] || die "the tarball's bitcoin-cli says \"$V\", not v$NEW"
echo "$V ($MINE; the other tarball was checked by hash and file list, not run)"
cd - >/dev/null

echo "== $OLD -> $NEW in lib.sh, README.md, INSTALL.md"
python3 - "$OLD" "$NEW" <<'PY'
import sys
old, new = sys.argv[1:3]
lines = (("lib.sh", "\nPLUMB_VER=%s\n"), ("README.md", "\n| Plumb %s ("), ("INSTALL.md", "\n    V=%s\n"))
# Check all three before writing any, so a failure changes nothing.
texts = {}
for path, line in lines:
	texts[path] = open(path).read()
	n = texts[path].count(line % old)
	if n != 1:
		sys.exit("error: %s has %d copies of the old version line, expected 1; nothing changed" % (path, n))
for path, line in lines:
	open(path, "w").write(texts[path].replace(line % old, line % new))
PY
git diff --stat -- lib.sh README.md INSTALL.md
git diff -- lib.sh README.md INSTALL.md
base=${NEW%.plumb*}
[ "$base" = "$KNOTS_VER" ] || echo "note: Plumb $NEW is built on Knots $base, but KNOTS_VER (the knots choice) is still $KNOTS_VER"
echo "next: ./install.sh --dry-run --address <addr> --mode pool --node new, then commit"
