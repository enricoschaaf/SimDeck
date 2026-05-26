# SimDeck CI Proxy Worker

Stateless Cloudflare Worker for password-gating temporary SimDeck CI tunnel
links.

CI posts a stable Worker URL with an encoded payload:

```text
https://ci.simdeck.sh/?redirect=<base64url-payload>
```

The payload points at the temporary Cloudflare Tunnel. When a session password
is configured, the SimDeck daemon token is encrypted with that password before
it is placed in the payload, so decoding the URL is not enough to bypass the
prompt.

Deploy from the Cloudflare dashboard with:

- Root directory: `packages/ci-proxy-worker`
- Install command: `npm ci`
- Build command: `npm run build`
- Deploy command: `npm run deploy`

Or deploy locally:

```sh
cd packages/ci-proxy-worker
npm ci
npm run deploy
```
