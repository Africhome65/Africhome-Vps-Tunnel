# Africhome Licence Manager

A small Cloudflare Worker + static dashboard for issuing per-VPS Ed25519-signed licence tokens. It uses Cloudflare Pages/Workers infrastructure and D1; a paid domain is not required (the Worker can use its `workers.dev` address).

## Security model

- The browser never receives the signing private key.
- Set the Ed25519 PKCS#8 private key as the Worker secret `LICENSE_PRIVATE_KEY_PKCS8_B64`.
- Set `ADMIN_PASSWORD` and a long random `SESSION_SECRET` as Worker secrets.
- Admin sessions are HttpOnly, Secure, SameSite=Strict cookies with an eight-hour lifetime.
- D1 stores licence IDs, expiry dates, fingerprints, and generated tokens.
- HTTPS is provided by Cloudflare.
- This first version is an offline-style issuer: revoking a record in D1 does not invalidate a token already installed on a VPS. Online revocation is not implemented.

## Important: key setup is required

The repository currently contains a public key at `../keys/license-public.pem`. A matching private key has not yet been generated and verified. Do not deploy the issuer or issue customer licences until the key pair is created and the public key in the tunnel installer is updated to match it. Never commit the private key or place it in `public/`.

The private key must be Ed25519 PKCS#8 PEM. Convert its PEM body to one-line base64 for the Worker secret, or use a secure local conversion process. Do not paste the private key into chat.

## Cloudflare setup (after key pair is ready)

1. Install Node.js and Wrangler on a trusted computer, or use Cloudflare's dashboard tools where available.
2. Create a D1 database named `africhome-licences`.
3. Replace `REPLACE_WITH_D1_DATABASE_ID` in `wrangler.toml` with the database ID.
4. From this directory, apply the schema: `npx wrangler d1 migrations apply africhome-licences --remote`.
5. Set secrets: `npx wrangler secret put ADMIN_PASSWORD`, `SESSION_SECRET`, and `LICENSE_PRIVATE_KEY_PKCS8_B64`.
6. Deploy: `npx wrangler deploy`.
7. Open the assigned `workers.dev` URL and sign in.

Do not enable public access to the D1 database or expose secrets in frontend variables.

## Current limitations

- No self-service customer portal.
- No online licence revocation/check-in.
- No automated key rotation.
- The installer verifies signatures, expiry and VPS fingerprint locally; it cannot know about later D1 changes.
- Admin login is password-based. Restrict the Worker URL and use a unique high-entropy password.
