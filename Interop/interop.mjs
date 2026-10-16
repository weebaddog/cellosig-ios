// Cross-implementation check: the Swift core vs. the Node implementation that
// the relay's test bot uses (itself byte-compatible with the Android app).
//
//   node Interop/interop.mjs gen    <dir>   -> <dir>/vectors.json (Node encrypts, Swift must decrypt)
//   (swift test reads vectors.json, writes <dir>/swift-out.json)
//   node Interop/interop.mjs verify <dir>   -> Node decrypts everything Swift produced
//
// Self-contained (node:crypto only). Test keys are throwaway.
import {
  generateKeyPairSync, diffieHellman, createPublicKey, createPrivateKey, hkdfSync, createHmac,
  randomBytes, createCipheriv, createDecipheriv, sign, verify, createHash,
} from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const X_SPKI = Buffer.from("302a300506032b656e032100", "hex");
const X_PKCS8 = Buffer.from("302e020100300506032b656e04220420", "hex");
const ED_SPKI = Buffer.from("302a300506032b6570032100", "hex");
const ED_PKCS8 = Buffer.from("302e020100300506032b657004220420", "hex");
const b64 = (b) => Buffer.from(b).toString("base64");
const unb64 = (s) => Buffer.from(s, "base64");

function x25519() {
  const { publicKey, privateKey } = generateKeyPairSync("x25519");
  return { priv: privateKey.export({ type: "pkcs8", format: "der" }).subarray(-32), pub: publicKey.export({ type: "spki", format: "der" }).subarray(-32) };
}
function ed25519() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  return { priv: privateKey.export({ type: "pkcs8", format: "der" }).subarray(-32), pub: publicKey.export({ type: "spki", format: "der" }).subarray(-32) };
}
const edPriv = (seed) => createPrivateKey({ key: Buffer.concat([ED_PKCS8, seed]), format: "der", type: "pkcs8" });
const edPub = (raw) => createPublicKey({ key: Buffer.concat([ED_SPKI, raw]), format: "der", type: "spki" });
function dh(priv32, pub32) {
  return diffieHellman({
    privateKey: createPrivateKey({ key: Buffer.concat([X_PKCS8, priv32]), format: "der", type: "pkcs8" }),
    publicKey: createPublicKey({ key: Buffer.concat([X_SPKI, pub32]), format: "der", type: "spki" }),
  });
}
const hkdf = (ikm, salt, info, len) => Buffer.from(hkdfSync("sha256", ikm, salt, Buffer.from(info), len));
const hmac = (k, d) => createHmac("sha256", k).update(d).digest();
function seal(key, pt, aad) {
  const iv = randomBytes(12), c = createCipheriv("aes-256-gcm", key, iv);
  c.setAAD(aad);
  const ct = Buffer.concat([c.update(pt), c.final()]);
  return Buffer.concat([iv, ct, c.getAuthTag()]);
}
function open(key, blob, aad) {
  const d = createDecipheriv("aes-256-gcm", key, blob.subarray(0, 12));
  d.setAAD(aad);
  d.setAuthTag(blob.subarray(blob.length - 16));
  return Buffer.concat([d.update(blob.subarray(12, blob.length - 16)), d.final()]);
}
const be32 = (v) => { const b = Buffer.alloc(4); b.writeInt32BE(v); return b; };

// Chunked attachments (CSv2)
const MAGIC = Buffer.from("CSv2"), CHUNK = 64 * 1024;
const chunkNA = (prefix, i, final) => [Buffer.concat([prefix, be32(i)]), Buffer.concat([be32(i), Buffer.from([final ? 1 : 0])])];
function sealChunked(key, pt) {
  const prefix = randomBytes(8), out = [MAGIC, be32(CHUNK), prefix];
  const n = Math.max(1, Math.ceil(pt.length / CHUNK));
  for (let i = 0; i < n; i++) {
    const [nonce, aad] = chunkNA(prefix, i, i === n - 1);
    const c = createCipheriv("aes-256-gcm", key, nonce);
    c.setAAD(aad);
    out.push(c.update(pt.subarray(i * CHUNK, (i + 1) * CHUNK)), c.final(), c.getAuthTag());
  }
  return Buffer.concat(out);
}
function openChunked(key, blob) {
  if (!blob.subarray(0, 4).equals(MAGIC)) throw new Error("not CSv2");
  const chunk = blob.readUInt32BE(4), prefix = blob.subarray(8, 16), body = blob.subarray(16), step = chunk + 16, out = [];
  const n = Math.max(1, Math.ceil(body.length / step));
  for (let i = 0; i < n; i++) {
    const part = body.subarray(i * step, (i + 1) * step);
    const [nonce, aad] = chunkNA(prefix, i, i === n - 1);
    const d = createDecipheriv("aes-256-gcm", key, nonce);
    d.setAAD(aad);
    d.setAuthTag(part.subarray(part.length - 16));
    out.push(d.update(part.subarray(0, part.length - 16)), d.final());
  }
  return Buffer.concat(out);
}

// Sealed sender
function sealedSeal(senderIk, recipientIk, cert, envJson) {
  const e = x25519();
  const okm1 = hkdf(dh(e.priv, recipientIk), Buffer.concat([e.pub, recipientIk]), "cellosig/sealed/v1/eph", 64);
  const encIk = seal(okm1.subarray(32), senderIk.pub, e.pub);
  const k2 = hkdf(dh(senderIk.priv, recipientIk), Buffer.concat([okm1.subarray(0, 32), encIk]), "cellosig/sealed/v1/static", 32);
  const ct = seal(k2, Buffer.from(JSON.stringify({ cert, env: envJson })), Buffer.concat([e.pub, encIk]));
  return { eph: b64(e.pub), ik: b64(encIk), ct: b64(ct) };
}
function sealedOpen(myIk, box, serverPub) {
  const ePub = unb64(box.eph), encIk = unb64(box.ik);
  const okm1 = hkdf(dh(myIk.priv, ePub), Buffer.concat([ePub, myIk.pub]), "cellosig/sealed/v1/eph", 64);
  const senderIk = open(okm1.subarray(32), encIk, ePub);
  const k2 = hkdf(dh(myIk.priv, senderIk), Buffer.concat([okm1.subarray(0, 32), encIk]), "cellosig/sealed/v1/static", 32);
  const content = JSON.parse(open(k2, unb64(box.ct), Buffer.concat([ePub, encIk])).toString());
  if (!verify(null, Buffer.from(content.cert.data), edPub(serverPub), unb64(content.cert.sig))) throw new Error("bad cert sig");
  const data = JSON.parse(content.cert.data);
  if (!unb64(data.ik).equals(senderIk)) throw new Error("cert for other ik");
  return { sender: data.phone, env: JSON.parse(content.env) };
}
const certFor = (server, phone, ikPub) => {
  const data = JSON.stringify({ phone, ik: b64(ikPub), exp: Date.now() + 24 * 3600_000 });
  return { data, sig: b64(sign(null, Buffer.from(data), edPriv(server.priv))) };
};

// X3DH + Double Ratchet
const F = Buffer.alloc(32, 0xff), ZERO32 = Buffer.alloc(32);
const kdfRoot = (rk, o) => { const x = hkdf(o, rk, "cellosig/ratchet/rk", 64); return [x.subarray(0, 32), x.subarray(32)]; };
const kdfChain = (ck) => [hmac(ck, Buffer.from([2])), hmac(ck, Buffer.from([1]))];
const headerBytes = (h) => Buffer.concat([h.dhPub, be32(h.pn), be32(h.n)]);
class Ratchet {
  constructor(s) { this.s = s; }
  static initiator(sk, remoteSpk) { const dhs = x25519(); const [rk, cks] = kdfRoot(sk, dh(dhs.priv, remoteSpk)); return new Ratchet({ rk, dhs, dhr: remoteSpk, cks, ckr: null, ns: 0, nr: 0, pn: 0, skipped: new Map() }); }
  static responder(sk, spk) { return new Ratchet({ rk: sk, dhs: spk, dhr: null, cks: null, ckr: null, ns: 0, nr: 0, pn: 0, skipped: new Map() }); }
  encrypt(pt, ad) { const s = this.s; const [ck, mk] = kdfChain(s.cks); s.cks = ck; const h = { dhPub: s.dhs.pub, pn: s.pn, n: s.ns }; s.ns++; return { h, ct: seal(mk, pt, Buffer.concat([ad, headerBytes(h)])) }; }
  decrypt(h, ct, ad) {
    const s = this.s, key = `${b64(h.dhPub)}:${h.n}`;
    if (s.skipped.has(key)) { const mk = s.skipped.get(key); s.skipped.delete(key); return open(mk, ct, Buffer.concat([ad, headerBytes(h)])); }
    if (!s.dhr || !h.dhPub.equals(s.dhr)) {
      this.skip(h.pn); s.pn = s.ns; s.ns = 0; s.nr = 0; s.dhr = h.dhPub;
      [s.rk, s.ckr] = kdfRoot(s.rk, dh(s.dhs.priv, h.dhPub)); s.dhs = x25519(); [s.rk, s.cks] = kdfRoot(s.rk, dh(s.dhs.priv, h.dhPub));
    }
    this.skip(h.n);
    const [ck, mk] = kdfChain(s.ckr); s.ckr = ck; s.nr++;
    return open(mk, ct, Buffer.concat([ad, headerBytes(h)]));
  }
  skip(until) { const s = this.s; if (!s.ckr) return; while (s.nr < until) { const [ck, mk] = kdfChain(s.ckr); s.skipped.set(`${b64(s.dhr)}:${s.nr}`, mk); s.ckr = ck; s.nr++; } }
  toJSON() {
    const s = this.s, o = (b) => (b ? b64(b) : null);
    return { rk: o(s.rk), dhsPriv: o(s.dhs.priv), dhsPub: o(s.dhs.pub), dhr: o(s.dhr), cks: o(s.cks), ckr: o(s.ckr), ns: s.ns, nr: s.nr, pn: s.pn, skipped: [...s.skipped].map(([k, v]) => [k, b64(v)]) };
  }
  static fromJSON(j) {
    const u = (x) => (x ? unb64(x) : null);
    return new Ratchet({ rk: u(j.rk), dhs: { priv: u(j.dhsPriv), pub: u(j.dhsPub) }, dhr: u(j.dhr), cks: u(j.cks), ckr: u(j.ckr), ns: j.ns, nr: j.nr, pn: j.pn, skipped: new Map(j.skipped.map(([k, v]) => [k, unb64(v)])) });
  }
}
const envOf = (h, ct, extra = {}) => ({ kind: "normal", dhPub: b64(h.dhPub), pn: h.pn, n: h.n, ct: b64(ct), ...extra });
const pad = (obj) => { const raw = Buffer.from(JSON.stringify(obj)); const len = Math.max(1, Math.ceil(raw.length / 256)) * 256; return Buffer.concat([raw, Buffer.alloc(len - raw.length, 0x20)]); };
const kp = (k) => ({ priv: b64(k.priv), pub: b64(k.pub) });
const unkp = (k) => ({ priv: unb64(k.priv), pub: unb64(k.pub) });

// Safety number (Signal NumericFingerprintGenerator shape), for a fixed expected value.
function safetyNumber(localId, localIk, remoteId, remoteIk) {
  const fp = (id, ik) => {
    const pk = Buffer.concat([Buffer.from([5]), ik]);
    let h = Buffer.concat([Buffer.from([0, 0]), pk, Buffer.from(id)]);
    for (let i = 0; i < 5200; i++) h = createHash("sha512").update(h).update(pk).digest();
    let s = "";
    for (let o = 0; o < 30; o += 5) s += String(Number(h.readUIntBE(o, 5) % 100000)).padStart(5, "0");
    return s;
  };
  const a = fp(localId, localIk), b = fp(remoteId, remoteIk);
  return a <= b ? a + b : b + a;
}

function gen(dir) {
  const server = ed25519();
  const alice = { phone: "+15550000001", ik: x25519() };
  const bob = { phone: "+15550000002", ik: x25519(), ed: ed25519(), spk: x25519(), opk: x25519(), opkId: 7 };
  const dave = { phone: "+15550000004", ik: x25519(), ed: ed25519(), spk: x25519(), opk: x25519(), opkId: 3 };
  const swiftIdentity = x25519(); // the Swift side's own identity when it initiates (as "carol")

  // Node "alice" starts a session with Swift-as-bob, then sends 4 messages.
  const ek = x25519();
  const sk = hkdf(Buffer.concat([F, dh(alice.ik.priv, bob.spk.pub), dh(ek.priv, bob.ik.pub), dh(ek.priv, bob.spk.pub), dh(ek.priv, bob.opk.pub)]), ZERO32, "cellosig/x3dh/v1", 32);
  const r = Ratchet.initiator(sk, bob.spk.pub);
  const ad = Buffer.concat([alice.ik.pub, bob.ik.pub]);
  const bodies = ["hello from node", "second", "third (arrives before second)", "fourth 🎉 ünïcödé"];
  const envs = bodies.map((body, i) => {
    const p = pad({ t: "text", id: `m${i}`, body, ak: b64(Buffer.alloc(32, 9)) });
    const { h, ct } = r.encrypt(p, ad);
    return i === 0 ? envOf(h, ct, { kind: "prekey", ikPub: b64(alice.ik.pub), ekPub: b64(ek.pub), opkId: bob.opkId }) : envOf(h, ct);
  });
  // A fifth message delivered sealed.
  const p5 = pad({ t: "text", id: "m4", body: "sealed hello" });
  const e5 = r.encrypt(p5, ad);
  const sealed = sealedSeal(alice.ik, bob.ik.pub, certFor(server, alice.phone, alice.ik.pub), JSON.stringify(envOf(e5.h, e5.ct)));

  const fileKey = randomBytes(32), file = randomBytes(150_000);
  const davePub = {
    username: dave.phone, identityKey: b64(dave.ik.pub), signingKey: b64(dave.ed.pub), signedPreKey: b64(dave.spk.pub),
    signedPreKeySig: b64(sign(null, dave.spk.pub, edPriv(dave.ed.priv))), oneTimePreKey: { id: dave.opkId, key: b64(dave.opk.pub) },
  };
  const fixedA = Buffer.alloc(32, 0x11), fixedB = Buffer.alloc(32, 0x22);

  const vectors = {
    server: kp(server),
    alice: { phone: alice.phone, ik: kp(alice.ik), state: r.toJSON(), ad: b64(ad) },
    bob: { phone: bob.phone, ik: kp(bob.ik), ed: kp(bob.ed), spk: kp(bob.spk), opk: kp(bob.opk), opkId: bob.opkId },
    deliver: [0, 2, 1, 3].map((i) => ({ envelope: envs[i], body: bodies[i] })),
    sealed: { box: sealed, sender: alice.phone, body: "sealed hello" },
    dave: { phone: dave.phone, ik: kp(dave.ik), spk: kp(dave.spk), opk: kp(dave.opk), bundle: davePub },
    carol: { phone: "+15550000003", ik: kp(swiftIdentity) },
    file: { key: b64(fileKey), blob: b64(sealChunked(fileKey, file)), sha256: createHash("sha256").update(file).digest("hex") },
    safety: { a: "+15550000001", aKey: b64(fixedA), b: "+15550000002", bKey: b64(fixedB), expected: safetyNumber("+15550000001", fixedA, "+15550000002", fixedB) },
    hkdf: { ikm: b64(Buffer.from("ikm")), salt: b64(Buffer.from("salt")), info: "info", out: b64(hkdf(Buffer.from("ikm"), Buffer.from("salt"), "info", 64)) },
  };
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "vectors.json"), JSON.stringify(vectors, null, 1));
  console.log(`wrote ${path.join(dir, "vectors.json")}`);
}

function verifyOut(dir) {
  const v = JSON.parse(fs.readFileSync(path.join(dir, "vectors.json"), "utf8"));
  const out = JSON.parse(fs.readFileSync(path.join(dir, "swift-out.json"), "utf8"));
  let fails = 0;
  const ok = (c, m) => { console.log(`${c ? "  ok  " : "  FAIL"} - ${m}`); if (!c) fails++; };
  const tryOk = (m, f) => { try { ok(f(), m); } catch (e) { ok(false, `${m}: ${e.message}`); } };

  // 1. Swift (as bob) replied on node alice's session.
  const alice = Ratchet.fromJSON(v.alice.state), ad = unb64(v.alice.ad);
  for (const rep of out.replies) {
    tryOk(`node decrypts Swift reply "${rep.body}"`, () => {
      const e = rep.envelope;
      const pt = alice.decrypt({ dhPub: unb64(e.dhPub), pn: e.pn, n: e.n }, unb64(e.ct), ad);
      const p = JSON.parse(pt.toString().trimEnd());
      return p.body === rep.body && pt.length % 256 === 0;
    });
  }

  // 2. Swift (as carol) started a session with node dave.
  const dave = { ik: unkp(v.dave.ik), spk: unkp(v.dave.spk), opk: unkp(v.dave.opk) };
  let daveR, daveAd;
  out.toDave.forEach((m, i) => tryOk(`node dave decrypts Swift message ${i} (${m.envelope.kind})`, () => {
    const e = m.envelope;
    if (e.kind === "prekey") {
      if (e.opkId !== v.dave.bundle.oneTimePreKey.id) throw new Error("wrong opk id");
      const ikA = unb64(e.ikPub), ekA = unb64(e.ekPub);
      const sk = hkdf(Buffer.concat([F, dh(dave.spk.priv, ikA), dh(dave.ik.priv, ekA), dh(dave.spk.priv, ekA), dh(dave.opk.priv, ekA)]), ZERO32, "cellosig/x3dh/v1", 32);
      daveR = Ratchet.responder(sk, dave.spk);
      daveAd = Buffer.concat([ikA, dave.ik.pub]);
    }
    const pt = daveR.decrypt({ dhPub: unb64(e.dhPub), pn: e.pn, n: e.n }, unb64(e.ct), daveAd);
    return JSON.parse(pt.toString()).body === m.body;
  }));

  // 3. A sealed box from Swift (carol) to dave, certificate signed with the test server key.
  tryOk("node opens Swift's sealed box and checks its certificate", () => {
    const o = sealedOpen(dave.ik, out.sealedToDave.box, unb64(v.server.pub));
    const pt = daveR.decrypt({ dhPub: unb64(o.env.dhPub), pn: o.env.pn, n: o.env.n }, unb64(o.env.ct), daveAd);
    return o.sender === v.carol.phone && JSON.parse(pt.toString()).body === out.sealedToDave.body;
  });

  // 4. Attachment encrypted by Swift.
  tryOk("node decrypts Swift's CSv2 attachment", () => {
    const pt = openChunked(unb64(out.file.key), unb64(out.file.blob));
    return createHash("sha256").update(pt).digest("hex") === out.file.sha256 && pt.length === out.file.size;
  });

  // 5. Swift's Ed25519 signature over a signed prekey.
  tryOk("node verifies Swift's signed-prekey signature", () =>
    verify(null, unb64(out.bundle.signedPreKey), edPub(unb64(out.bundle.signingKey)), unb64(out.bundle.signedPreKeySig)));

  console.log(fails === 0 ? "\nINTEROP: ALL PASS" : `\nINTEROP: ${fails} FAILURE(S)`);
  process.exit(fails === 0 ? 0 : 1);
}

const [cmd, dir] = process.argv.slice(2);
if (cmd === "gen") gen(dir);
else if (cmd === "verify") verifyOut(dir);
else { console.error("usage: interop.mjs gen|verify <dir>"); process.exit(2); }
