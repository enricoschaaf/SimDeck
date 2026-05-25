# SimDeck CI Proxy Worker

Stateless Cloudflare Worker for password-gating temporary SimDeck CI tunnel
links.

CI posts a stable Worker URL with an encoded payload:

```text
https://simdeck-ci-proxy.djdeveloperr.workers.dev/?redirect=<base64url-payload>
```

The payload points at the temporary Cloudflare Tunnel. When a session password
is configured, the SimDeck daemon token is encrypted with that password before
it is placed in the payload, so decoding the URL is not enough to bypass the
prompt.

Deploy:

```sh
cd packages/ci-proxy-worker
npm install
npm run deploy
```

Later, attach `ci.simdeck.sh` to this Worker in Cloudflare.
