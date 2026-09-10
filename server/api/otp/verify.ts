import type { VercelRequest, VercelResponse } from "@vercel/node";
import { issueToken } from "../../lib/auth.js";
import { badRequest, bodyOf, json, normalizePhone } from "../../lib/http.js";
import { devCodeMatches, isDevPhone, verifyCode } from "../../lib/otp.js";

/** POST { phone, method_id, code } -> { token, phone } */
export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return json(res, 405, { error: "POST only" });
  const body = bodyOf(req);
  const phone = normalizePhone(body.phone);
  const methodId = typeof body.method_id === "string" ? body.method_id : "";
  const code = typeof body.code === "string" ? body.code.trim() : "";
  if (!phone || !methodId || !code) return badRequest(res, "Missing code.");

  let verifiedPhone: string;
  if (isDevPhone(phone) && methodId === "dev") {
    if (!devCodeMatches(code)) return json(res, 401, { error: "That code didn't match." });
    verifiedPhone = phone;
  } else {
    const result = await verifyCode(phone, methodId, code);
    if (result.error || !result.phone) return json(res, 401, { error: result.error ?? "That code didn't match." });
    // Trust the number Stytch verified, never the one echoed by the client.
    if (result.phone !== phone) return json(res, 401, { error: "The verified number did not match this sign-in." });
    verifiedPhone = result.phone;
  }
  return json(res, 200, { token: await issueToken(verifiedPhone), phone: verifiedPhone });
}
