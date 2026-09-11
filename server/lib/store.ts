/**
 * Storage layout in S3 (one object per uploaded batch, newline-delimited JSON):
 *   points/<phone digits>/<YYYY-MM-DD>/<first ts ms>-<random>.jsonl
 * Reads list the day prefixes in range and concatenate. No database.
 */
import {
  DeleteObjectsCommand,
  GetObjectCommand,
  ListObjectsV2Command,
  PutObjectCommand,
  S3Client,
} from "@aws-sdk/client-s3";

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

// Bounds for a plausible epoch-ms timestamp: 2000-01-01 to a day in the
// future. Anything outside (e.g. 1e300) would make new Date(ts).toISOString()
// throw a RangeError downstream, so such points are dropped at the door.
const TS_MIN = 946_684_800_000;
const tsMax = () => Date.now() + 86_400_000;

export function parsePoints(raw: unknown): Point[] {
  if (!Array.isArray(raw)) return [];
  const out: Point[] = [];
  const upper = tsMax();
  for (const item of raw) {
    if (!item || typeof item !== "object") continue;
    const p = item as Record<string, unknown>;
    const ts = Number(p.ts), lat = Number(p.lat), lon = Number(p.lon);
    if (!Number.isFinite(ts) || !Number.isFinite(lat) || !Number.isFinite(lon)) continue;
    if (Math.abs(lat) > 90 || Math.abs(lon) > 180) continue;
    if (ts < TS_MIN || ts > upper) continue;
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

/** Fetch one object and return its parsed points, skipping corrupt lines. */
async function readObject(key: string): Promise<Point[]> {
  const got = await client.send(new GetObjectCommand({ Bucket: bucket(), Key: key }));
  const text = (await got.Body?.transformToString()) ?? "";
  const out: Point[] = [];
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    try {
      out.push(JSON.parse(line) as Point);
    } catch {
      /* skip a corrupt line rather than fail the whole read */
    }
  }
  return out;
}

/** Run `worker` over `items` with at most `limit` in flight at once. */
async function mapLimit<T, R>(items: T[], limit: number, worker: (item: T) => Promise<R>): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let next = 0;
  async function run(): Promise<void> {
    while (true) {
      const i = next++;
      if (i >= items.length) return;
      results[i] = await worker(items[i]);
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, run));
  return results;
}

/**
 * Every point for `phone` between two UTC dates (inclusive), oldest first.
 * A busy day writes ~1 object/minute, so objects are fetched with bounded
 * concurrency — a sequential GET per object blew past the function timeout.
 */
export async function readPoints(phone: string, from: string, to: string): Promise<Point[]> {
  const keys: string[] = [];
  for (const day of daysBetween(from, to)) {
    const prefix = `points/${phoneKey(phone)}/${day}/`;
    let token: string | undefined;
    do {
      const listed = await client.send(
        new ListObjectsV2Command({ Bucket: bucket(), Prefix: prefix, ContinuationToken: token }),
      );
      for (const object of listed.Contents ?? []) {
        if (object.Key) keys.push(object.Key);
      }
      token = listed.IsTruncated ? listed.NextContinuationToken : undefined;
    } while (token);
  }
  const chunks = await mapLimit(keys, 24, readObject);
  const points = chunks.flat();
  points.sort((a, b) => a.ts - b.ts);
  // De-duplicate by timestamp: a lost upload response makes the client re-send
  // a batch, so the same fix can land in two objects. Two genuinely distinct
  // fixes at the same millisecond are not meaningful here, so one-per-ts is the
  // right collapse.
  const deduped: Point[] = [];
  let lastTs: number | undefined;
  for (const p of points) {
    if (p.ts !== lastTs) {
      deduped.push(p);
      lastTs = p.ts;
    }
  }
  return deduped;
}

/**
 * Permanently deletes every location object for `phone` (an account deletion,
 * as Apple's guideline 5.1.1(v) requires). Returns the number of objects
 * removed. S3 deletes up to 1,000 keys per request.
 */
export async function deleteAllPoints(phone: string): Promise<number> {
  const prefix = `points/${phoneKey(phone)}/`;
  let deleted = 0;
  let token: string | undefined;
  do {
    const listed = await client.send(
      new ListObjectsV2Command({ Bucket: bucket(), Prefix: prefix, ContinuationToken: token }),
    );
    const objects = (listed.Contents ?? []).filter((o) => o.Key).map((o) => ({ Key: o.Key! }));
    if (objects.length > 0) {
      await client.send(new DeleteObjectsCommand({ Bucket: bucket(), Delete: { Objects: objects } }));
      deleted += objects.length;
    }
    token = listed.IsTruncated ? listed.NextContinuationToken : undefined;
  } while (token);
  return deleted;
}
