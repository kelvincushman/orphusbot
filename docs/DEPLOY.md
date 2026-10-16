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
       reverse_proxy 127.0.0.1:7480
   }
   ```

   Caddy gets and renews the certificate itself. It passes the event stream (SSE) and the node's WebSocket through without extra settings.

5. **Server settings.** Keep the server on loopback behind Caddy, and tell it the address browsers use:

   ```sh
   ORPHUSBOT_BIND=127.0.0.1:7480
   ORPHUSBOT_ORIGIN=https://bots.example.com
   ```

   With an `https` origin, session cookies are also marked `Secure`.

6. **Nodes** connect through Caddy with TLS: `ORPHUSBOT_SERVER=wss://bots.example.com/node`. Enrol each machine once with a code from **Add a node** on the page (`orphusbot-node enrol <code>`); the GPU box's own node enrols the same way.

7. **First sign-in.** Open `https://bots.example.com` from a device on NetBird, enter the setup token (`ORPHUSBOT_SETUP_TOKEN`), and add a passkey when asked. From then on, sign in with the passkey. Add one passkey per device, or use a passkey manager that syncs them.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| The name doesn't resolve on one device | Some routers and DNS filters (Pi-hole, NextDNS, "DNS rebinding protection") refuse answers that point at private addresses. Allow the name, or let NetBird's DNS answer for it |
| Caddy can't get a certificate | Check the API token's permission and zone, and that Caddy was built with the Cloudflare module (`caddy list-modules` should list `dns.providers.cloudflare`) |
| The page says passkeys don't work, or the prompt fails at once | The page isn't on HTTPS with the exact `ORPHUSBOT_ORIGIN` host, or the browser is too old (it needs the WebAuthn JSON helpers: Chrome 129 or Firefox 119 or newer, or a current Safari) |
| Every passkey is lost | Remove the `passkey` rows in Postgres (`delete from passkey;`). That signs out every session and turns the setup token back on |
