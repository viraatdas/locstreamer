/**
 * Phone OTP. The app only ever talks to this API; no web view is involved.
 * Two providers, chosen by which env vars are present:
 *
 *  1. Bridge (default): the Manas `stytch-auth` Supabase edge function sends
 *     the SMS through Stytch and returns a Supabase session on success. We
 *     confirm that session with Supabase's own /auth/v1/user and take the
 *     verified phone from there, so the Stytch secret never has to leave
 *     Manas. Env: OTP_BRIDGE_URL, OTP_BRIDGE_ANON_KEY (a publishable key).
 *  2. Direct Stytch: STYTCH_PROJECT_ID + STYTCH_SECRET (+ STYTCH_BASE_URL).
 *
 * Optional allowlist for one number with a fixed code and no SMS:
 * DEV_PHONE (E.164) + DEV_CODE.
 */

export function isDevPhone(phone: string): boolean {
  const dev = process.env.DEV_PHONE;
  return !!dev && !!process.env.DEV_CODE && dev === phone;
}

export function devCodeMatches(code: string): boolean {
  return !!process.env.DEV_CODE && process.env.DEV_CODE === code;
}

export function smsConfigured(): boolean {
  return directConfigured() || bridgeConfigured();
}

function directConfigured(): boolean {
  return !!process.env.STYTCH_PROJECT_ID && !!process.env.STYTCH_SECRET;
}

function bridgeConfigured(): boolean {
  return !!process.env.OTP_BRIDGE_URL && !!process.env.OTP_BRIDGE_ANON_KEY;
}

function normalize(phone: string): string {
  return `+${phone.replace(/[^0-9]/g, "")}`;
}

type Send = { methodId?: string; error?: string };
type Verify = { phone?: string; error?: string };

/** Sends the SMS; returns the method id the verify step needs. */
export async function sendCode(phone: string): Promise<Send> {
  return directConfigured() ? stytchSend(phone) : bridgeSend(phone);
}

/** Verifies the code and returns the phone the provider actually verified. */
export async function verifyCode(phone: string, methodId: string, code: string): Promise<Verify> {
  return directConfigured() ? stytchVerify(methodId, code) : bridgeVerify(phone, methodId, code);
}

// MARK: - Bridge (Manas edge function)

function bridgeHeaders(): Record<string, string> {
  const key = process.env.OTP_BRIDGE_ANON_KEY!;
  return { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" };
}

async function bridgeSend(phone: string): Promise<Send> {
  const r = await fetch(process.env.OTP_BRIDGE_URL!, {
    method: "POST",
    headers: bridgeHeaders(),
    body: JSON.stringify({ action: "send", phone }),
  });
  const d = (await r.json()) as { method_id?: string; error?: string };
  if (!r.ok || !d.method_id) return { error: d.error ?? "Couldn't send the code." };
  return { methodId: d.method_id };
}

async function bridgeVerify(phone: string, methodId: string, code: string): Promise<Verify> {
  const r = await fetch(process.env.OTP_BRIDGE_URL!, {
    method: "POST",
    headers: bridgeHeaders(),
    body: JSON.stringify({ action: "verify", phone, method_id: methodId, code }),
  });
  const d = (await r.json()) as { session?: { access_token?: string }; error?: string };
  const accessToken = d.session?.access_token;
  if (!r.ok || !accessToken) return { error: d.error ?? "That code didn't match." };

  // Don't trust the bridge's JSON for identity: ask the auth server who this
  // token belongs to. OTP_BRIDGE_URL is <project>/functions/v1/<name>.
  const authURL = process.env.OTP_BRIDGE_URL!.replace(/\/functions\/v1\/.*$/, "/auth/v1/user");
  const u = await fetch(authURL, {
    headers: { apikey: process.env.OTP_BRIDGE_ANON_KEY!, Authorization: `Bearer ${accessToken}` },
  });
  const user = (await u.json()) as { phone?: string; phone_confirmed_at?: string };
  if (!u.ok || !user.phone || !user.phone_confirmed_at) return { error: "The session could not be confirmed." };
  return { phone: normalize(user.phone) };
}

// MARK: - Direct Stytch

const STYTCH_BASE = process.env.STYTCH_BASE_URL ?? "https://api.stytch.com";

function stytchAuth(): string {
  return "Basic " + Buffer.from(`${process.env.STYTCH_PROJECT_ID}:${process.env.STYTCH_SECRET}`).toString("base64");
}

async function stytchSend(phone: string): Promise<Send> {
  const r = await fetch(`${STYTCH_BASE}/v1/otps/sms/login_or_create`, {
    method: "POST",
    headers: { Authorization: stytchAuth(), "Content-Type": "application/json" },
    body: JSON.stringify({ phone_number: phone, expiration_minutes: 10 }),
  });
  const d = (await r.json()) as { phone_id?: string; error_message?: string };
  if (!r.ok) return { error: d.error_message ?? "Couldn't send the code." };
  return { methodId: d.phone_id };
}

async function stytchVerify(methodId: string, code: string): Promise<Verify> {
  const r = await fetch(`${STYTCH_BASE}/v1/otps/authenticate`, {
    method: "POST",
    headers: { Authorization: stytchAuth(), "Content-Type": "application/json" },
    body: JSON.stringify({ method_id: methodId, code, session_duration_minutes: 5 }),
  });
  const d = (await r.json()) as {
    error_message?: string;
    user?: { phone_numbers?: Array<{ phone_id?: string; phone_number?: string }> };
  };
  if (!r.ok) return { error: d.error_message ?? "That code didn't match." };
  const match = d.user?.phone_numbers?.find((p) => p.phone_id === methodId);
  if (!match?.phone_number) return { error: "The verified number did not match this sign-in." };
  return { phone: normalize(match.phone_number) };
}
