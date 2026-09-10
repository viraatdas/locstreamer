/**
 * Storage layout in S3 (one object per uploaded batch, newline-delimited JSON):
 *   points/<phone digits>/<YYYY-MM-DD>/<first ts ms>-<random>.jsonl
 * Reads list the day prefixes in range and concatenate. No database.
 */
import { GetObjectCommand, ListObjectsV2Command, PutObjectCommand, S3Client } from "@aws-sdk/client-s3";

export interface Point {
  /** Unix epoch milliseconds. */
  ts: number;
  lat: number;
  lon: number;
  /** Horizontal accuracy in metres, if known. */
  acc?: number;
  /** Speed in m/s, if known. */
  spd?: number;
}

const client = new S3Client({ region: process.env.AWS_REGION ?? "us-east-1" });

function bucket(): string {
  const name = process.env.S3_BUCKET;
  if (!name) throw new Error("S3_BUCKET is not set");
  return name;
}

function dayOf(ts: number): string {
  return new Date(ts).toISOString().slice(0, 10);
}

function phoneKey(phone: string): string {
  return phone.replace(/[^0-9]/g, "");
}

export function parsePoints(raw: unknown): Point[] {
  if (!Array.isArray(raw)) return [];
  const out: Point[] = [];
  for (const item of raw) {
    if (!item || typeof item !== "object") continue;
    const p = item as Record<string, unknown>;
    const ts = Number(p.ts), lat = Number(p.lat), lon = Number(p.lon);
    if (!Number.isFinite(ts) || !Number.isFinite(lat) || !Number.isFinite(lon)) continue;
    if (Math.abs(lat) > 90 || Math.abs(lon) > 180) continue;
    const point: Point = { ts: Math.round(ts), lat, lon };
    if (Number.isFinite(Number(p.acc))) point.acc = Number(p.acc);
    if (Number.isFinite(Number(p.spd))) point.spd = Number(p.spd);
    out.push(point);
  }
  return out;
}

/** Writes one batch per UTC day it spans; returns the keys written. */
export async function appendPoints(phone: string, points: Point[]): Promise<string[]> {
  const byDay = new Map<string, Point[]>();
  for (const p of points) {
    const day = dayOf(p.ts);
    byDay.set(day, [...(byDay.get(day) ?? []), p]);
  }
  const keys: string[] = [];
  for (const [day, dayPoints] of byDay) {
    dayPoints.sort((a, b) => a.ts - b.ts);
    const rand = Math.random().toString(36).slice(2, 8);
    const key = `points/${phoneKey(phone)}/${day}/${dayPoints[0].ts}-${rand}.jsonl`;
    await client.send(
      new PutObjectCommand({
        Bucket: bucket(),
        Key: key,
        Body: dayPoints.map((p) => JSON.stringify(p)).join("\n") + "\n",
        ContentType: "application/x-ndjson",
      }),
    );
    keys.push(key);
  }
  return keys;
}

function* daysBetween(from: string, to: string): Generator<string> {
  const cursor = new Date(`${from}T00:00:00Z`);
  const end = new Date(`${to}T00:00:00Z`);
  while (cursor <= end) {
    yield cursor.toISOString().slice(0, 10);
    cursor.setUTCDate(cursor.getUTCDate() + 1);
  }
}

/** Every point for `phone` between two UTC dates (inclusive), oldest first. */
export async function readPoints(phone: string, from: string, to: string): Promise<Point[]> {
  const points: Point[] = [];
  for (const day of daysBetween(from, to)) {
    const prefix = `points/${phoneKey(phone)}/${day}/`;
    let token: string | undefined;
    do {
      const listed = await client.send(
        new ListObjectsV2Command({ Bucket: bucket(), Prefix: prefix, ContinuationToken: token }),
      );
      for (const object of listed.Contents ?? []) {
        if (!object.Key) continue;
        const got = await client.send(new GetObjectCommand({ Bucket: bucket(), Key: object.Key }));
        const text = (await got.Body?.transformToString()) ?? "";
        for (const line of text.split("\n")) {
          if (!line.trim()) continue;
          try {
            points.push(JSON.parse(line) as Point);
          } catch {
            /* skip a corrupt line rather than fail the whole read */
          }
        }
      }
      token = listed.IsTruncated ? listed.NextContinuationToken : undefined;
    } while (token);
  }
  points.sort((a, b) => a.ts - b.ts);
  return points;
}
