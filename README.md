# knots-datum-node

**Status: in testing, not released yet.** It has not been run end to end on
a real machine. Wait for version 0.1.0 before relying on it.

Run your own Bitcoin node and DATUM gateway, so the blocks your miners work
on are built by your node, not by a pool.

It runs as an ordinary user. The only steps that need an administrator are
listed up front, and the script tells you if any are missing.

## Which setup is right for you

- **You bought an ASIC miner and it is at your home.** Run this on a computer
  at home that stays on. Your miner connects to it over your home network.
  Nothing is exposed to the internet.
- **You rent hashpower.** The rental service connects to your gateway from the
  internet, so run this on a rented server. (A home computer also works if you
  can forward a port on your router, but a server is simpler.)

**Already run a Bitcoin Knots node** (on this computer, or another one on
your network, such as an Umbrel or Start9)? The install can use it, and
skip downloading a second copy of the chain. It asks.

## What you need

- A computer running Linux with systemd: Debian, Ubuntu, Fedora, Arch,
  openSUSE and their relatives all work. For a new node, 4 GB of memory and
  60 GB of free disk is comfortable; 2 GB and 40 GB is the minimum. With a
  node you already run, any small computer will do.
- Time and data, for a new node. After the install, your node downloads
  and checks the whole Bitcoin chain before your miners can connect. That takes most of a
  day and downloads about 800 GB. If your internet plan has a data
  cap, check it first.
- You do not need 800 GB of disk. The node checks each block and then
  deletes the old ones, so it keeps only a small part of what it downloads.
  The 40 GB above is enough.
- For a rented server, read "Choosing a server" below first.
- A Bitcoin address for your rewards.

## Step 1: administrator setup

These are the only commands that need `sudo`. On Debian or Ubuntu:

    sudo apt-get update
    sudo apt-get install -y git curl gnupg ca-certificates python3 iproute2 build-essential cmake pkgconf libcurl4-openssl-dev libjansson-dev libsodium-dev libmicrohttpd-dev
    sudo useradd --create-home --shell /bin/bash miner
    sudo loginctl enable-linger miner
    sudo -iu miner

The first two lines install what the node and gateway are built from. The
next two create an account called `miner` that runs everything, and let its
programs keep running after you log out. The last one switches to that
account. On other distributions, skip the two install lines: the script
prints the right ones for your system in step 4.

## Step 2: download it and check the signature

As the `miner` user:

    git clone https://github.com/jasonsopko/knots-datum-node installer
    cd installer
    gpg --keyserver hkps://keys.openpgp.org --recv-keys 89F0E41D72CE523F4AA1CDB692CDFFB7C40CD1BA
    git verify-commit HEAD

The last command must print these two lines (along with a few others):

    gpg: Good signature from "Jason Sopko <jason@sopko.net>" [unknown]
    Primary key fingerprint: 89F0 E41D 72CE 523F 4AA1  CDB6 92CD FFB7 C40C D1BA

It also warns that the key "is not certified with a trusted signature".
That is normal: it means you have not told gpg to trust this key, not that
anything is wrong. What matters is `Good signature` and that fingerprint,
which you can compare with https://github.com/jasonsopko.gpg.

If it says `BAD signature`, or shows a different fingerprint, stop.

## Step 3: see what it will do

    ./install.sh --dry-run

It asks for your settings (see "Your settings" below), then prints every
download, file and service the install would create. It changes nothing.

## Step 4: install

    ./install.sh

It asks the same questions, then installs. If anything from step 1 is
missing, it stops and prints the exact commands an administrator needs to
run. It also prints firewall commands; on a home computer you can ignore
them.

## Step 5: wait for the sync

Your node now downloads and checks the whole chain. That takes most of a
day. Check on it with:

    ~/knots-datum-node/status

Miners cannot connect until it says `synced`.

## Step 6: point your miners at it

Use the address the install printed at the end. It looks like
`stratum+tcp://192.168.1.50:23334`.

- **ASIC at home:** open your miner's web page, go to its pool settings, and
  enter that address as the pool URL. Any worker name, password `x`.
- **Rented hashpower:** give the rental service
  `stratum+tcp://YOUR-SERVER-IP:23334` as the pool, with any worker name and
  password `x`. If your server has a firewall turned on, run the firewall
  commands the install printed first.

## Step 7: check your miners on the dashboard

The end of the install, and `~/knots-datum-node/status`, show the
dashboard's address. At home it looks like `http://192.168.1.50:7152`: open
it in a web browser and log in as `admin` with your dashboard password.
Each miner that has connected is listed with its hashrate. If a miner is
missing, check the pool address you gave it in step 6.

Forgot the password? `~/knots-datum-node/configure --show-password`.

On a rented server the dashboard is not reachable from the internet. From
your own computer, run `ssh -L 7152:127.0.0.1:7152 USER@YOUR-SERVER-IP`
and open `http://127.0.0.1:7152` while that stays connected.

Safari cannot log in to the dashboard; use Firefox, Chrome or Edge.

## Your settings

The install asks six things. Press Enter to take the suggestion in
brackets.

- **Which node.** `new` installs Bitcoin Knots here. `existing` uses a
  Knots node you already run (version 29.4.1 or later), here or on your
  network. For an existing node it makes a login only for the gateway and
  prints the lines to add to that node's `bitcoin.conf`, limited to the
  calls the gateway needs; you restart the node, and it checks the
  connection. If you cannot edit that node's `bitcoin.conf` (some node
  appliances do not allow it), type the RPC username you already have
  instead, and it asks for the password.

- **Payout address.** The Bitcoin address your rewards go to.
- **Pool or solo.** Either way, your own node builds every block your
  miners work on and chooses which transactions go in it.
  - **Pool:** your gateway connects to a DATUM pool over the DATUM protocol
    and sends it proof of the work your miners do. When anyone mining with
    the pool finds a block, the reward is split among the pool's miners by
    their recent work. CONVOY pays each miner's share straight to their
    address inside that block, once it is above CONVOY's payout threshold.
    How the split and the threshold work:
    [convoy.xyz/docs/tides](https://convoy.xyz/docs/tides). If the pool
    cannot be reached, your miners pause; they do not switch to solo.
  - **Solo:** nobody else is involved. If your miners find a block, the
    whole reward is paid straight to your address, inside that block. If
    they do not, you get nothing. How often you find one depends on your
    share of all the mining on the network, and there is no payment in
    between.
- **Which pool.** CONVOY unless you type another DATUM pool's server address
  and public key, which that pool publishes.
- **Your short name.** Written into every block you find, where anyone can
  read it. Leave it empty to stay anonymous. In solo mode it also asks for
  the main name on your blocks.
- **Dashboard password.** The gateway has a web page showing each connected
  miner and its hashrate. You log in as `admin` with this password; press
  Enter to have one made for you. At home it also asks whether other
  computers on your network may open the page (`network`) or only this one
  (`local`). On a rented server it stays on the server; see step 7.

To change any of them later, run:

    ~/knots-datum-node/configure

It asks the same questions with your current answers as the suggestions,
and restarts the gateway with the new ones. Your node keeps running. It can
also move the gateway from the node this installed to one you already run.

Settings can also be given as flags, for scripted installs:
`--address`, `--mode pool|solo`, `--tag`, `--primary-tag`, `--pool-host`,
`--pool-pubkey`, and `--node new` or `--node HOST[:PORT] --rpc-user USER`
with the password in `NODE_RPC_PASSWORD`. See `./install.sh --help`.

## Choosing a server

Read the provider's terms of service for "mining" and "blockchain" before
you rent. The gateway hashes nothing, but it hands out mining work, and a
provider that bans mining can count it. Losing the account takes your node
with it.

- Hetzner prohibits crypto mining, and their support has said the ban covers
  node hosting and anything related to mining
  ([report](https://www.bleepingcomputer.com/news/cryptocurrency/hetzner-cloud-server-provider-bans-cryptocurrency-mining/)).
  Do not use it for this.
- DigitalOcean's [acceptable use policy](https://www.digitalocean.com/legal/acceptable-use-policy)
  prohibits mining without their written permission. Ask them first.
- Some providers state outright that Bitcoin nodes are allowed. Pick one of
  those, and keep the page that says so.

Check the monthly transfer allowance too. The first sync downloads about
800 GB, and some cheap plans cap transfer at 1 TB or charge for more.

If only your own miners will connect and their address does not change, add
`--miner-ip THEIR-IP` to the install command, and it prints firewall commands
that keep everyone else out.

## What gets downloaded, and how it is checked

The script downloads two things and stops unless both check out:

| What | From | Checked by |
| --- | --- | --- |
| Bitcoin Knots 29.4.2 | bitcoinknots.org | The list of file hashes must be signed by Luke Dashjr's release key `1A3E 761F 19D2 CC77 85C5 502E A291 A2C4 5D0C 504A`, and the download must match it |
| DATUM gateway source | github.com/CONVOYMining/datum_gateway | Fetched by exact commit, `6ccfbe55a7e7cd6c066aa428e771a37a22e92277`: CONVOY's code plus the fix in CONVOYMining/datum_gateway#18 |

The only other requests are for Luke's public key (from keys.openpgp.org and
the Knots guix.sigs repository; the fingerprint check is what counts). There
is no telemetry. `INSTALL.md` walks through the same steps by hand.

## How it is set up

- A pruned Bitcoin Knots node, in `~/knots-datum-node`.
- The DATUM gateway, limited by systemd: it cannot gain privileges, run
  unexpected system calls, or use more than 1 GB of memory, and it accepts at
  most 256 miner connections. Its login to the node can make only the five
  calls it needs.
- Both run as user services of the `miner` account, and start again after a
  reboot.

## Removing it

    ./install.sh --uninstall

This stops and removes everything except the downloaded chain, and prints the
command to delete that too.

## License

MIT. See `LICENSE`.
