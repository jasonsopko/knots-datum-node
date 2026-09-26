# Installing by hand

This does what `install.sh` does, one step at a time, for anyone who would
rather type the commands than run the script. The numbered steps match the
numbered sections of `./install.sh --dry-run`.

Do the administrator setup from step 1 of the README first, then everything
below as the `miner` user, without `sudo`.

File contents are not repeated here. Run the dry run with your own settings
and copy each file from its section:

    ./install.sh --dry-run | tee plan.txt

Where a file holds a password, the dry run shows a placeholder. Step 3
covers making the real ones.

    mkdir -p ~/knots-datum-node/bin ~/knots-datum-node/bitcoin ~/knots-datum-node/gateway ~/knots-datum-node/conf ~/.config/systemd/user
    chmod 700 ~/knots-datum-node ~/knots-datum-node/conf

## 1. Bitcoin Knots

Download the release, its hash list, and the signature on the hash list.
Use `aarch64-linux-gnu` in place of `x86_64-linux-gnu` on an arm64 computer.

    V=29.4.2.knots20260508
    cd /tmp
    curl -O https://bitcoinknots.org/files/29.x/$V/SHA256SUMS
    curl -O https://bitcoinknots.org/files/29.x/$V/SHA256SUMS.asc
    curl -O https://bitcoinknots.org/files/29.x/$V/bitcoin-$V-x86_64-linux-gnu.tar.gz

Get Luke Dashjr's release key and check the signature. The output must say
`Good signature` and show the fingerprint
`1A3E 761F 19D2 CC77 85C5  502E A291 A2C4 5D0C 504A`.

    gpg --keyserver hkps://keys.openpgp.org --recv-keys 1A3E761F19D2CC7785C5502EA291A2C45D0C504A
    gpg --verify SHA256SUMS.asc SHA256SUMS

Check the download against the signed list, then put the two programs in
place:

    sha256sum --ignore-missing -c SHA256SUMS
    tar xzf bitcoin-$V-x86_64-linux-gnu.tar.gz
    install -m 755 bitcoin-$V/bin/bitcoind bitcoin-$V/bin/bitcoin-cli ~/knots-datum-node/bin/

## 2. DATUM gateway

Fetch the exact commit and build it:

    git init gw && cd gw
    git fetch --depth 1 https://github.com/CONVOYMining/datum_gateway.git 6ccfbe55a7e7cd6c066aa428e771a37a22e92277
    git checkout FETCH_HEAD
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
    cmake --build build -j$(nproc)
    install -m 755 build/datum_gateway ~/knots-datum-node/bin/

That commit is CONVOY's code plus the fix in CONVOYMining/datum_gateway#18,
which you can read on GitHub before building.

## 3. Node configuration

Make a password for the gateway's login to the node, and the matching
`rpcauth` line:

    RPC_PASS=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
    python3 -c 'import hmac,secrets,sys; s=secrets.token_hex(16); print("gateway:%s$%s" % (s, hmac.new(s.encode(), sys.argv[1].encode(), "sha256").hexdigest()))' "$RPC_PASS"
    echo "$RPC_PASS"

Write `~/knots-datum-node/conf/bitcoin.conf` from section 3 of the dry run, with
the printed `gateway:...` value on the `rpcauth=` line, then:

    chmod 600 ~/knots-datum-node/conf/bitcoin.conf

## 4. Gateway configuration

Write `~/knots-datum-node/conf/datum_gateway.json` from section 4. Put `$RPC_PASS`
in `rpcpassword`, and a password of your own in `admin_password` (it
protects the gateway's dashboard), then:

    chmod 600 ~/knots-datum-node/conf/datum_gateway.json

## 5 and 6. Services

Write the two files in `~/.config/systemd/user/` from sections 5 and 6.

## 7. Status and configure commands

Write `~/knots-datum-node/status` from section 7 and `chmod 755` it. Copy
`configure.sh` to `~/knots-datum-node/configure` and `lib.sh` to
`~/knots-datum-node/lib.sh`, so you can change settings later.

## 8. Start

    systemctl --user daemon-reload
    systemctl --user enable --now knots-datum-node-bitcoind.service knots-datum-node-gateway.service

If `systemctl --user` says it cannot connect to the bus, run
`export XDG_RUNTIME_DIR=/run/user/$(id -u)` and try again.

## 9. Firewall

If the computer has a firewall turned on, an administrator runs the
commands from section 9.

The node now checks the chain from the beginning, which takes most of a
day. `~/knots-datum-node/status` shows progress.

## Using a node you already run

Skip steps 1, 3 and 5, and do not create `~/knots-datum-node/bitcoin`.
In their place, add a login for the gateway to that node's `bitcoin.conf`:
section 3 of the dry run, run with `existing`, shows the exact lines. The
`rpcwhitelistdefault=0` line matters: without it, adding a whitelist line
locks the node's other logins out. Restart that node. In the gateway
configuration from section 4, `rpcurl`, `rpcuser` and `rpcpassword` point
at that node, and the gateway's service in section 6 has no `After=` or
`Requires=` lines.
