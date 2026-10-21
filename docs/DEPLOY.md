# Deploying OrphusBot on your own network

How to run the server on an always-on machine (the "GPU box") so your laptop, desktop and phone can reach it over [NetBird](https://netbird.io) with HTTPS and passkeys. For running everything on one machine while developing, see [DEVELOPMENT.md](DEVELOPMENT.md).

## Why a domain name and a certificate

Passkeys only work on a page served over HTTPS from a **host name**, not an IP address, and the browser must trust the certificate. So the server needs a name such as `bots.example.com`, and a real certificate for it.

The name can point at the GPU box's **private NetBird address**. That makes it reachable only from devices on your NetBird network; nothing is exposed to the internet. A certificate authority can't connect to a private address to check you own the name, so the certificate is issued with a **DNS challenge**: you prove ownership by letting the certificate tool add a temporary DNS record. (DECISIONS D-016.)

This guide uses Cloudflare for DNS and [Caddy](https://caddyserver.com) for HTTPS; any DNS provider that Caddy or `lego` supports works the same way.

## What you need

- A domain whose DNS you control (here, on Cloudflare).
- The GPU box on your NetBird network. Note its NetBird address: `netbird status` shows it, in the `100.64.0.0/10` range.
- Postgres, the server binary and the steps from [DEVELOPMENT.md](DEVELOPMENT.md) working on that box.

## Steps

1. **DNS record.** In Cloudflare, add an `A` record: name `bots`, value the GPU box's NetBird address, proxy status **DNS only** (grey cloud). Cloudflare can't proxy a private address, and the traffic must stay on NetBird.

2. **API token for the DNS challenge.** In Cloudflare, create an API token with the **Zone → DNS → Edit** permission for this one zone only. Keep it on the GPU box, for example in `/etc/caddy/cloudflare.env` as `CF_API_TOKEN=…` with mode `0600`. Never commit it.

3. **Caddy with the Cloudflare module.** The stock Caddy package doesn't include DNS providers. Either download a build that includes `github.com/caddy-dns/cloudflare` from the [Caddy download page](https://caddyserver.com/download), or run `caddy add-package github.com/caddy-dns/cloudflare` on an existing binary.

4. **Caddyfile.** Replace the host name and address:

   ```caddyfile
   bots.example.com {
       # Listen only on the NetBird interface, never on a public one.
       bind 100.64.0.10
       tls {
           dns cloudflare {env.CF_API_TOKEN}
       }
       encode zstd gzip
       reverse_proxy 127.0.0.1:7480
   }
   ```

   Caddy gets and renews the certificate itself. It passes the event stream (SSE) and the node's WebSocket through without extra settings.

5. **Server settings.** Keep the server on loopback behind Caddy, and tell it the address browsers use:

   ```sh
   ORPHUSBOT_BIND=127.0.0.1:7480
   ORPHUSBOT_ORIGIN=https://bots.example.com
   ORPHUSBOT_UI_DIR=/opt/orphusbot/ui   # the contents of crates/ui/dist after `trunk build --release`
   ```

   With an `https` origin, session cookies are also marked `Secure`.

6. **System 1 (optional).** Run kev on the GPU box bound to loopback as a user service (see [DEVELOPMENT.md](DEVELOPMENT.md#system-1-kev-or-laya); on the owner's box it is `orphusbot-kev` on port 8009) and set `ORPHUSBOT_LAYA_URL=http://127.0.0.1:8009` for the server. laya-serve works the same way on a machine without a large GPU.
7. **Push (optional).** For the phone app (D-041): run OrphusBot's own [ntfy](https://ntfy.sh) on the GPU box on loopback (for example `docker run -d --name orphusbot-ntfy -p 127.0.0.1:7482:80 …`) with `base-url: https://push.example.com`, `behind-proxy: true`, an `auth-file` and `auth-default-access: deny-all`, then `ntfy access everyone 'up*' read-write` so only UnifiedPush's random topics are open. Publish it as `push.example.com` (the same Cloudflare tunnel works: add an ingress rule and `cloudflared tunnel route dns`). On the phone, install the ntfy app, set its default server to `https://push.example.com`, and open OrphusBot: it registers by itself. The older single-topic push still works with `ORPHUSBOT_NTFY_URL` and `ORPHUSBOT_NTFY_TOKEN`.
8. **Secrets (optional).** To keep tokens for connections, make a 32-byte key and hand it to the server as a systemd credential, so it never sits in plain text on disk: `head -c 32 /dev/urandom | sudo systemd-creds encrypt --name=orphusbot-secret-key - /etc/credstore.encrypted/orphusbot-secret-key`, then in the unit `LoadCredentialEncrypted=orphusbot-secret-key` and `Environment=ORPHUSBOT_SECRET_KEY_FILE=%d/orphusbot-secret-key`. Back the key up somewhere safe: without it the stored tokens can't be read.
9. **Nodes** connect through Caddy with TLS: `ORPHUSBOT_SERVER=wss://bots.example.com/node`. Enrol each machine once with a code from **Add a node** on the page (`orphusbot-node enrol <code>`); the GPU box's own node enrols the same way.

10. **First sign-in.** Open `https://bots.example.com` from a device on NetBird, enter the setup token (`ORPHUSBOT_SETUP_TOKEN`), and add a passkey when asked. From then on, sign in with the passkey. Add one passkey per device, or use a passkey manager that syncs them.

## Before the domain: running it now, over an SSH tunnel

Everything except HTTPS can run today without the domain or Caddy. This is how the GPU box runs it until steps 1–5 are done:

- **Programs:** build on the box (`SQLX_OFFLINE=true cargo build --release -p orphusbot-server -p orphusbot-node`), and copy `crates/ui/dist` from a machine with Trunk.
- **Database:** its own container, loopback only: `docker run -d --name orphusbot-postgres --restart unless-stopped -p 127.0.0.1:5433:5432 --env-file ~/.config/orphusbot/pg.env -v orphusbot-pg:/var/lib/postgresql/data postgres:16-alpine`.
- **Settings:** `~/.config/orphusbot/server.env` and `node.env`, mode `0600` (the database URL, `ORPHUSBOT_SETUP_TOKEN`, `ORPHUSBOT_BIND=127.0.0.1:7480`, `ORPHUSBOT_ORIGIN=http://localhost:7480`, `ORPHUSBOT_SECRET_KEY_FILE`; the node's `ORPHUSBOT_SERVER=ws://127.0.0.1:7480/node`, `ORPHUS_BIN`, `ORPHUSBOT_COMPUTER_IMAGE`).
- **Services:** systemd user units `orphusbot-server` and `orphusbot-node` with `EnvironmentFile=`, and `loginctl enable-linger` so they start at boot.
- **Computers:** rootless Podman (`apt install podman uidmap passt nftables`) and `podman build -t localhost/orphusbot-desktop images/desktop`.
- **Two things Ubuntu needs, or computers won't start (they fail closed):**
  - the node's `PATH` must include `/usr/sbin`, where `nft` is;
  - the `nft_reject_inet`, `nft_reject_ipv4` and `nft_reject_ipv6` kernel modules must be loaded (`modprobe`, and list them in `/etc/modules-load.d/orphusbot.conf`), because a rootless container can't load them itself.
- **Clients:** each laptop keeps a tunnel open, `ssh -N -L 127.0.0.1:7480:127.0.0.1:7480 <user>@<gpu-box>` (a systemd user unit with `Restart=always` works well), and uses `http://localhost:7480`. Passkeys work there, because browsers treat `localhost` as secure. Passkeys made on `localhost` don't carry over to the domain later; add new ones then.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| The name doesn't resolve on one device | Some routers and DNS filters (Pi-hole, NextDNS, "DNS rebinding protection") refuse answers that point at private addresses. Allow the name, or let NetBird's DNS answer for it |
| Caddy can't get a certificate | Check the API token's permission and zone, and that Caddy was built with the Cloudflare module (`caddy list-modules` should list `dns.providers.cloudflare`) |
| The page says passkeys don't work, or the prompt fails at once | The page isn't on HTTPS with the exact `ORPHUSBOT_ORIGIN` host, or the browser is too old (it needs the WebAuthn JSON helpers: Chrome 129 or Firefox 119 or newer, or a current Safari) |
| Every passkey is lost | Remove the `passkey` rows in Postgres (`delete from passkey;`). That signs out every session and turns the setup token back on |
