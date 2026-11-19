const encoder = new TextEncoder();

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" }
  });
}
function b64(bytes) {
  let binary = "";
  for (const byte of new Uint8Array(bytes)) binary += String.fromCharCode(byte);
  return btoa(binary);
}
function b64url(bytes) {
  return b64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}
function unb64url(value) {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - value.length % 4) % 4);
  return Uint8Array.from(atob(padded), c => c.charCodeAt(0));
}
async function digest(value) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value)));
}
function constantTimeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}
async function signSession(payload, secret) {
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const body = b64url(encoder.encode(JSON.stringify(payload)));
  const sig = b64url(await crypto.subtle.sign("HMAC", key, encoder.encode(body)));
  return body + "." + sig;
}
async function validSession(request, env) {
  const cookie = request.headers.get("Cookie") || "";
  const match = cookie.match(/(?:^|; )africhome_admin=([^;]+)/);
  if (!match || !env.SESSION_SECRET) return false;
  const parts = match[1].split(".");
  if (parts.length !== 2) return false;
  const key = await crypto.subtle.importKey("raw", encoder.encode(env.SESSION_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  let body;
  let sig;
  try { body = unb64url(parts[0]); sig = unb64url(parts[1]); } catch { return false; }
  const ok = await crypto.subtle.verify("HMAC", key, sig, encoder.encode(parts[0]));
  if (!ok) return false;
  try {
    const payload = JSON.parse(new TextDecoder().decode(body));
    return payload.exp > Math.floor(Date.now() / 1000);
  } catch { return false; }
}
function cookie(value, maxAge) {
  return `africhome_admin=${value}; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=${maxAge}`;
}
async function privateKey(env) {
  if (!env.LICENSE_PRIVATE_KEY_PKCS8_B64) throw new Error("Signing key is not configured yet.");
  const raw = Uint8Array.from(atob(env.LICENSE_PRIVATE_KEY_PKCS8_B64), c => c.charCodeAt(0));
  return crypto.subtle.importKey("pkcs8", raw, { name: "Ed25519" }, false, ["sign"]);
}
async function handleApi(request, env) {
  const url = new URL(request.url);
  if (url.pathname === "/api/login" && request.method === "POST") {
    const body = await request.json().catch(() => ({}));
    if (typeof body.password !== "string" || !env.ADMIN_PASSWORD || !env.SESSION_SECRET) return json({ error: "Login is not configured." }, 503);
    const [provided, expected] = await Promise.all([digest(body.password), digest(env.ADMIN_PASSWORD)]);
    if (!constantTimeEqual(provided, expected)) return json({ error: "Incorrect password." }, 401);
    const token = await signSession({ exp: Math.floor(Date.now() / 1000) + 8 * 60 * 60 }, env.SESSION_SECRET);
    return new Response(JSON.stringify({ ok: true }), { headers: { "content-type": "application/json", "cache-control": "no-store", "set-cookie": cookie(token, 28800) } });
  }
  if (url.pathname === "/api/logout" && request.method === "POST") {
    return new Response(JSON.stringify({ ok: true }), { headers: { "content-type": "application/json", "set-cookie": cookie("", 0), "cache-control": "no-store" } });
  }
  if (!(await validSession(request, env))) return json({ error: "Please sign in again." }, 401);
  if (!env.DB) return json({ error: "Database is not configured." }, 503);
  if (url.pathname === "/api/licenses" && request.method === "GET") {
    const { results } = await env.DB.prepare("SELECT id, expires, fingerprint, created_at, status FROM licences ORDER BY created_at DESC LIMIT 200").all();
    return json({ licences: results || [] });
  }
  if (url.pathname === "/api/licenses" && request.method === "POST") {
    const body = await request.json().catch(() => ({}));
    const id = typeof body.id === "string" ? body.id.trim() : "";
    const expires = typeof body.expires === "string" ? body.expires : "";
    const fingerprint = typeof body.fingerprint === "string" ? body.fingerprint.toLowerCase() : "";
    if (!/^[A-Za-z0-9_-]{4,64}$/.test(id)) return json({ error: "Licence ID must be 4–64 letters, numbers, _ or -." }, 400);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(expires) || new Date(expires + "T00:00:00Z").toISOString().slice(0, 10) !== expires) return json({ error: "Enter a valid expiry date (YYYY-MM-DD)." }, 400);
    if (expires < new Date().toISOString().slice(0, 10)) return json({ error: "Expiry date cannot be in the past (UTC)." }, 400);
    if (!/^[a-f0-9]{64}$/.test(fingerprint)) return json({ error: "Fingerprint must be 64 lowercase hexadecimal characters." }, 400);
    try {
      const payload = `AFRICHOME-LICENSE-V1\nid=${id}\nexpires=${expires}\nfingerprint=${fingerprint}\n`;
      const key = await privateKey(env);
      const signature = await crypto.subtle.sign({ name: "Ed25519" }, key, encoder.encode(payload));
      const token = b64(encoder.encode(payload)) + "." + b64(signature);
      await env.DB.prepare("INSERT INTO licences (id, expires, fingerprint, token, status) VALUES (?, ?, ?, ?, 'active')").bind(id, expires, fingerprint, token).run();
      return json({ id, expires, fingerprint, token });
    } catch (error) {
      const message = String(error?.message || error);
      return json({ error: message.includes("UNIQUE") ? "That licence ID already exists." : message }, 500);
    }
  }
  return json({ error: "Not found." }, 404);
}
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname.startsWith("/api/")) {
      if (request.method !== "GET" && request.method !== "POST") return json({ error: "Method not allowed." }, 405);
      try { return await handleApi(request, env); }
      catch (error) { return json({ error: String(error?.message || error) }, 500); }
    }
    return env.ASSETS.fetch(request);
  }
};
