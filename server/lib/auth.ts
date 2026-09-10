import { SignJWT, jwtVerify } from "jose";
import type { VercelRequest } from "@vercel/node";

function secret(): Uint8Array {
  const value = process.env.TOKEN_SECRET;
  if (!value) throw new Error("TOKEN_SECRET is not set");
  return new TextEncoder().encode(value);
}

/** A long-lived device token bound to one verified phone number. */
export async function issueToken(phone: string): Promise<string> {
  return new SignJWT({})
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(phone)
    .setIssuedAt()
    .setExpirationTime("365d")
    .sign(secret());
}

/** The phone the bearer token was issued for, or null. */
export async function phoneFromBearer(req: VercelRequest): Promise<string | null> {
  const header = req.headers.authorization;
  if (!header?.startsWith("Bearer ")) return null;
  try {
    const { payload } = await jwtVerify(header.slice(7), secret(), { algorithms: ["HS256"] });
    return typeof payload.sub === "string" ? payload.sub : null;
  } catch {
    return null;
  }
}

/** Read access for any phone number: the shared API key from `x-api-key`. */
export function hasReadApiKey(req: VercelRequest): boolean {
  const expected = process.env.READ_API_KEY;
  const provided = req.headers["x-api-key"];
  if (!expected || typeof provided !== "string") return false;
  if (provided.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= provided.charCodeAt(i) ^ expected.charCodeAt(i);
  return diff === 0;
}
