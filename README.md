# knots-datum-node

Run your own DATUM gateway, so the blocks your miners work on are built by
your own Bitcoin node, not by a pool. It installs a node for you, or uses a
Knots node you already run, and sets up the gateway, a web dashboard and a
status command. A new node is [Plumb](https://github.com/plumb-node/plumb),
Bitcoin Knots with extra spam filters, unless you choose Knots as released
or the computer is ARM, which gets Knots.

It runs as an ordinary user. The only steps that need an administrator are
listed up front, and the script tells you if any are missing.

## Which setup is right for you

- **You bought an ASIC miner and it is at your home.** Run this on a computer
  at home that stays on. Your miner connects to it over your home network.
  Nothing is exposed to the internet.
- **You rent hashpower.** The rental service connects to your gateway from the
  internet, so run this on a rented server. (A home computer also works if you
  can forward a port on your router, but a server is simpler.)
- **You already run a Bitcoin Knots node**, on this computer or another one
  on your network, such as an Umbrel or Start9. The install can use it and
  skip downloading a second copy of the chain. It asks.

## What you need

- A computer running Linux with systemd: Debian, Ubuntu, Fedora, Arch,
  openSUSE and their relatives all work. For a new node, 4 GB of memory and
  60 GB of free disk is comfortable; 2 GB and 40 GB is the minimum. With a
  node you already run, any small computer will do.
- For a new node, time and internet data. Before your miners can connect,
  the node downloads and checks the whole Bitcoin chain: a day or more, and
  about 800 GB of downloads. If your internet plan has a data cap, check it
  first.
- You do not need 800 GB of disk. The node checks each block and then
  deletes the old ones, so it keeps only a small part of what it downloads.
- For a rented server, read "Choosing a server" below first.
- A Bitcoin address for your rewards.

## Step 1: administrator setup

These are the only commands that need `sudo`. On Debian or Ubuntu:

    sudo apt-get update
    sudo apt-get install -y git curl gnupg ca-certificates python3 iproute2 build-essential cmake pkgconf libcurl4-openssl-dev libjansson-dev libsodium-dev libmicrohttpd-dev
    sudo useradd --create-home --shell /bin/bash miner
    sudo loginctl enable-linger miner
    sudo -iu miner

The first two lines install what the gateway, and the node if you want one,
are built from. The next two create an account called `miner` that runs
everything, and let its programs keep running after you log out. The last
one switches to that account. On other distributions, skip the two install
lines: the script prints the right ones for your system in step 4.

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
run. At the end it prints the addresses you need for steps 6 and 7, and
firewall commands; on a home computer you can ignore those.

## Step 5: wait for the sync

With a new node, it now downloads and checks the whole chain. Check on it
with:

    ~/knots-datum-node/status

Miners cannot connect until it says `synced`. With a node you already run,
there is no wait if that node is synced.

## Step 6: point your miners at it

Use the mining address the install printed. It looks like
`stratum+tcp://192.168.1.50:23334`.

- **ASIC at home:** open your miner's web page, go to its pool settings, and
  enter that address as the pool URL. Any worker name, password `x`.
- **Rented hashpower:** give the rental service
  `stratum+tcp://YOUR-SERVER-IP:23334` as the pool, with any worker name and
  password `x`. If your server has a firewall turned on, run the firewall
  commands the install printed first.
- **Other people's miners,** with sharing turned on: the same pool URL,
  and the owner's own Bitcoin address as the username. See "Letting other
  people mine through your gateway".

## Step 7: check on it in the dashboard

The gateway has two web pages. The install, `configure` and `status` all
print their addresses. At home they look like this:

- `http://192.168.1.50:7152` shows the gateway's stats, with no login.
  Its Coinbaser page is the list of addresses a block would pay right
  now. In pool mode that list comes from the pool: with CONVOY, it is the
  miners whose share of recent work has passed CONVOY's payout threshold.
  Your address appears there once yours has, which with a single small
  miner can take a while; it does not mean anything is wrong.
- `http://192.168.1.50:7152/clients` lists each connected miner and its
  hashrate. Log in as `admin` with your dashboard password. If a miner is
  missing, check the mining address you gave it in step 6.

Forgot the password? `~/knots-datum-node/configure --show-password`.

On a rented server the pages are not reachable from the internet. From your
own computer, run `ssh -L 7152:127.0.0.1:7152 USER@YOUR-SERVER-IP` and open
`http://127.0.0.1:7152` while that stays connected.

Safari cannot log in to the dashboard; use Firefox, Chrome or Edge.

## Check that you are being paid

Do this once your miners are running, and again after any change to your
settings. Start with:

    ~/knots-datum-node/status

It prints the payout address the gateway is using. Compare it character
for character with the receiving address your wallet shows. If they
differ, fix it with `~/knots-datum-node/configure` before anything else.

**Pool mode, with CONVOY.** `status` also prints your stats page,
`https://convoy.xyz/stats/YOUR-ADDRESS`.

1. Within about 15 minutes of your miners starting, the page lists them
   under "Workers" and "Work In Reward Window" starts to grow. The 60-second
   and 5-minute hashrates there should come close to what your miners
   report; the 3-hour figure takes three hours to catch up.
2. Each time CONVOY finds a block, it appears under "Latest Earnings" with
   your part of it. These add up under "Unpaid Earnings" until they pass
   the payout threshold of 0.01048576 BTC.
3. Once they do, your address shows up on your gateway's Coinbaser page
   (`http://192.168.1.50:7152/coinbaser` at home). That is the list of
   payments in the block your own node is working on right now, so you
   can see your share before a block is found, not only after.
4. After the next CONVOY block, look up your address on a block explorer
   that follows this chain, such as [mempool.guide](https://mempool.guide).
   The payment is an output of that block's first transaction. It can be
   spent 100 blocks later.

If your miners show hashrate on `/clients` but the stats page stays empty
after half an hour, the address is the first thing to check. CONVOY takes
work sent under any name, including a wrong address, and gives no error.
The work is not credited to anyone.

**Solo mode.** Your gateway's Coinbaser page should list a single
payment: the whole reward, to your address. If your miners find a block,
look it up on the block explorer: the block's first transaction pays your
address, and it can be spent 100 blocks later.

## Your settings

The install asks eight things. Press Enter to take the suggestion in
brackets.

- **Which node.** `new` installs a node here. `existing` uses a
  Knots node you already run (version 29.4.1 or later), here or on your
  network. For an existing node it makes a login only for the gateway and
  prints the lines to add to that node's `bitcoin.conf`, limited to the
  calls the gateway needs; you restart the node, and it checks the
  connection. If you cannot edit that node's `bitcoin.conf` (some node
  appliances do not allow it), type the RPC username you already have
  instead, and it asks for the password. The gateway uses that node only
  for block templates and to send in blocks; all its own settings stay on
  this computer. The node's own policy decides which transactions go in the
  blocks.
- **Node software.** New node only. `plumb`, the suggestion, installs
  [Plumb](https://github.com/plumb-node/plumb): Bitcoin Knots plus the spam
  filters listed in its README, all turned on, so your node leaves more spam
  out of the blocks it builds and does not pass it on. It follows the same
  chain as Knots and keeps the same data, so you can switch either way by
  running the install again. `knots` installs Bitcoin Knots as released.
  Plumb's release is built and signed by Jason Sopko, who also signs this
  installer; it is one person's build, not a reproducible one. Knots'
  release is signed by Luke Dashjr. Plumb is built for x86_64 only, so ARM
  computers get Knots without being asked. When you update, it suggests
  the one you run now.
- **Payout address.** The Bitcoin address your rewards go to, in pool
  mode and solo alike. This is the one setting that decides who gets paid,
  so take it from a wallet you control and copy and paste it. A reward paid
  to a wrong address cannot be sent back, and a pool pays whatever address
  it is given without checking that it is yours. The install checks the
  address's built-in checksum, which catches almost any typo, but it
  cannot tell whether the address is yours. See "Check that you are being
  paid" below.
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
- **Shared.** Pool mode only. `yes` lets other people mine through your
  gateway, each paid to their own address; see "Letting other people mine
  through your gateway" below. `no` credits all work here to your payout
  address.
- **Your short name.** Written into every block you find, where anyone can
  read it. Leave it empty to stay anonymous. In solo mode it also asks for
  the main name on your blocks.
- **Dashboard password.** You log in to the miners page as `admin` with
  this password; press Enter to have one made for you. At home it also asks
  whether other computers on your network may open the pages (`network`)
  or only this one (`local`). On a rented server they stay on the server.

To change any of them later, except the node software, run:

    ~/knots-datum-node/configure

It asks the same questions with your current answers as the suggestions,
and restarts the gateway with the new ones. Your node keeps running. It can
also move the gateway from the node this installed to one you already run.
The dashboard's config page is read-only; settings change only here.

Settings can also be given as flags, for scripted installs: `--address`,
`--mode pool|solo`, `--tag`, `--primary-tag`, `--pool-host`,
`--pool-pubkey`, `--shared yes|no`, `--dashboard network|local`,
`--miner-ip`, `--software plumb|knots` (new node only), and
`--node new` or `--node HOST[:PORT] --rpc-user USER`. Passwords go in the
`NODE_RPC_PASSWORD` and `DASHBOARD_PASSWORD` environment variables. See
`./install.sh --help`.

## Updating

As the `miner` user:

    cd ~/installer
    git pull
    git verify-commit HEAD
    ./install.sh

Check the signature as in step 2. The install asks the questions again with
your current answers as the suggestions, keeps the chain it has already
downloaded, and restarts with the new version. A node running Knots stays on
Knots unless you answer `plumb`.

## If something is not working

- `~/knots-datum-node/status` says whether the node and the gateway are
  running, and how far the sync has got.
- The gateway's log: `journalctl --user -u knots-datum-node-gateway -n 50`
- The node's log, for a node this installed:
  `journalctl --user -u knots-datum-node-bitcoind -n 50`

## Letting other people mine through your gateway

In pool mode, family, friends or a mining club can point their miners at
your gateway and be paid to their own addresses. Answer `yes` to "shared"
during the install, or later with `~/knots-datum-node/configure`.

- Each person types their own Bitcoin address as their miner's username,
  copied from their wallet, optionally followed by `.name` (for example
  `bc1q....rig1`). Password `x`.
- The pool pays each address directly, inside the blocks it finds. Their
  earnings never pass through you.
- Your own miners can keep using plain names if they start with a dot,
  such as `.rig1`; those are credited to your payout address.
- Any other username, including a mistyped address, mines for nobody.
  CONVOY accepts the work and credits no one, with no error. After anyone
  connects, check the usernames on the miners page (`/clients`), and have
  each person check their own stats page as in "Check that you are being
  paid".
- People outside your home network can reach the gateway only if your
  router forwards the mining port (23334) to it. On a rented server, run
  the firewall commands the install printed.

Sharing is not offered in solo mode. There every block pays your address
alone, so sharing would mean holding other people's rewards and paying
them yourself.

What the people mining through you should know:

- Your node builds the blocks they work on, so your node chooses the
  transactions.
- They are trusting you to leave sharing on. With it off, their work is
  credited to your address. Their stats page would show it within minutes:
  hashrate there drops to zero while their miner keeps running.
- If the pool cannot be reached, the gateway disconnects every miner; it
  does not switch to solo mining for your address.
- CONVOY's terms do not allow reselling its service, so do not charge
  people to mine through your gateway.

For people you do not know, their own node, or CONVOY's own connection,
is the better choice. Every miner on a shared gateway works on one node's
blocks.

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

Check the monthly transfer allowance too. The first sync of a new node
downloads about 800 GB, and some cheap plans cap transfer at 1 TB or charge
for more.

The mining port is open to anyone who finds it, the way a pool's is. If
only your own miners will connect and their address does not change, add
`--miner-ip THEIR-IP` to the install command, and it prints firewall
commands that keep everyone else out.

## What gets downloaded, and how it is checked

The script downloads at most two things and stops unless both check out:

| What | From | Checked by |
| --- | --- | --- |
| Plumb 29.4.2.knots20260508.plumb6 (new node, unless you choose Knots) | github.com/plumb-node/plumb releases | The list of file hashes must be signed by Jason Sopko's key `89F0 E41D 72CE 523F 4AA1 CDB6 92CD FFB7 C40C D1BA`, and the download must match it |
| Bitcoin Knots 29.4.2 (new node, if you choose it, and on ARM) | bitcoinknots.org | The list of file hashes must be signed by Luke Dashjr's release key `1A3E 761F 19D2 CC77 85C5 502E A291 A2C4 5D0C 504A`, and the download must match it |
| DATUM gateway source | github.com/CONVOYMining/datum_gateway | Fetched by exact commit, `6ccfbe55a7e7cd6c066aa428e771a37a22e92277`: CONVOY's code plus the fix in CONVOYMining/datum_gateway#18 |

The only other requests are for the public key that signed the node release:
Jason's from github.com/jasonsopko.gpg, or Luke's from the Knots guix.sigs
repository, and from keys.openpgp.org for either. The fingerprint check is
what counts. There is no telemetry. `INSTALL.md` walks through the same
steps by hand.

## How it is set up

Everything lives in `~/knots-datum-node` and runs as user services of the
`miner` account, starting again after a reboot.

- For a new node, a pruned Plumb or Bitcoin Knots node.
- The DATUM gateway, limited by systemd: it cannot gain privileges, run
  unexpected system calls, or use more than 1 GB of memory, and it accepts
  at most 256 miner connections. Its login to the node can make only the
  eight calls it and the status command need.
- `status`, and `configure` for changing settings.

## Removing it

    ./install.sh --uninstall

This stops and removes everything except the downloaded chain, and prints the
command to delete that too. A node you already ran is left alone; the
gateway's login lines in its `bitcoin.conf` can be deleted by hand.

## License

MIT. See `LICENSE`.
