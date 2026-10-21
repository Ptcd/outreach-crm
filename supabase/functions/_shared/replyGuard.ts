// Hard rules for AI-suggested seller replies, from the WPIE repo (claude/real estate).
// Every word list and regex comes from replyRules.generated.ts, which
// tools/export_reply_prompt.py writes from wpie/sms/webhooks.py (opt-out) and
// wpie/reply/rules.py (price/offer). Only the few lines of algorithm around them
// are ported by hand, and replyRules.parity.test.ts checks them against the
// Python answers for every text in WPIE's red-team fixture.
// Pure functions only, so the tests can hit every branch.
import { SAFE_PRICE_DEFLECTION } from "./replyPrompt.generated.ts";
import * as R from "./replyRules.generated.ts";

export { SAFE_PRICE_DEFLECTION };

export const MAX_SUGGESTION_CHARS = 320; // two GSM segments, same as WPIE SMS_MAX_CHARS

const re = (spec: R.RegexSpec, extra = "") => new RegExp(spec.source, spec.flags + extra);

// --- Opt-out (wpie/sms/webhooks.py is_opt_out) --------------------------------
const OPTOUT_WORDS = new Set(R.OPTOUT_WORDS);
const OPTOUT_PHRASE = re(R.OPTOUT_PHRASE);
const LEGAL_THREAT = re(R.LEGAL_THREAT);
const SOFT_OPTOUT = re(R.SOFT_OPTOUT);
const CHANNEL_PREF = re(R.CHANNEL_PREF);
const NEGATED = re(R.NEGATED, "g");
const POLITE_TAIL = re(R.POLITE_TAIL, "g");
const POLITE_HEAD = re(R.POLITE_HEAD, "g");
const SHORT_STOP = re(R.SHORT_STOP);
const COMBINING_MARK = re(R.COMBINING_MARK, "g");

// webhooks._fold: lower case, accents dropped ("más" -> "mas"); letters, digits, apostrophes and spaces.
export function fold(text: string): string {
  const t = (text ?? "").toLowerCase().replace(/’/g, "'").normalize("NFKD").replace(COMBINING_MARK, "");
  return t.replace(/[^a-z0-9' ]/g, " ").replace(/\s+/g, " ").trim();
}

const squash = (s: string) => s.replace(/[ ']/g, "");

// Any removal request: carrier keyword, plain language, abuse, a legal threat, Spanish.
export function isOptOut(text: string): boolean {
  const normalized = fold(text);
  if (OPTOUT_WORDS.has(squash(normalized))) return true;                       // "S T O P"
  let core = normalized.replace(POLITE_TAIL, "").replace(POLITE_HEAD, "").trim(); // "unsubscribe pls"
  if (OPTOUT_WORDS.has(squash(core))) return true;
  core = core.replace(NEGATED, " ").replace(/\s+/g, " ").trim();                 // "don't remove me"
  if (OPTOUT_PHRASE.test(core) || LEGAL_THREAT.test(core)) return true;
  if (SOFT_OPTOUT.test(core) && !CHANNEL_PREF.test(core)) return true;
  return SHORT_STOP.test(core);
}

export function isHelpOrInfo(text: string): boolean {
  const t = (text ?? "").trim().toUpperCase();
  return t === "HELP" || t === "INFO";
}

// Whether to draft a suggestion at all for this inbound text.
export function shouldDraft(inbound: string): boolean {
  return !!(inbound ?? "").trim() && !isOptOut(inbound) && !isHelpOrInfo(inbound);
}

// --- Price / offer language (wpie/reply/rules.py find_price_or_offer) ----------
const PRICE_RE = re(R.PRICE, "g");
const OFFER_RE = re(R.OFFER, "g");
const ALLOWED_RE = re(R.ALLOWED, "g");

export function findPriceOrOffer(text: string): string[] {
  if (!text) return [];
  const scrubbed = text.replace(ALLOWED_RE, " ");
  return [...scrubbed.matchAll(PRICE_RE), ...scrubbed.matchAll(OFFER_RE)].map((m) => m[0]);
}

// --- Draft enforcement ---------------------------------------------------------
function escapeRe(s: string) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// Cut at a sentence boundary when one is reasonably far in, else at a word (wpie rules._trim).
function trim(text: string, limit: number): string {
  if (text.length <= limit) return text;
  const cut = text.slice(0, limit);
  for (const sep of [". ", "? ", "! "]) {
    const i = cut.lastIndexOf(sep);
    if (i > Math.floor(limit / 3)) return cut.slice(0, i + 1).trim();
  }
  const sp = cut.lastIndexOf(" ");
  return (sp > 0 ? cut.slice(0, sp) : cut).trim();
}

export type Guarded = { text: string; violations: string[]; blocked: string[] };

// Apply every rule to the model's draft. Returns empty text when nothing should be suggested.
export function guardDraft(
  draft: string,
  opts: { companyName?: string; ownerName?: string; maxChars?: number } = {},
): Guarded {
  const company = (opts.companyName ?? "Merrill Holdings").trim();
  const owner = opts.ownerName ?? "Colin";
  const max = opts.maxChars ?? MAX_SUGGESTION_CHARS;
  const out: Guarded = { text: (draft ?? "").trim(), violations: [], blocked: [] };
  out.text = out.text.replace(/\[[A-Z_]+\]/g, "");   // [END_CALL]-style markers
  out.text = out.text.replace(/[*_`#>]+/g, "");        // markdown
  out.text = out.text.replace(/\s+/g, " ").trim();
  if (!out.text) return { ...out, violations: ["empty"] };

  const hits = findPriceOrOffer(out.text);
  if (hits.length) {
    out.violations.push("price_or_offer");
    out.blocked = hits;
    out.text = SAFE_PRICE_DEFLECTION;
  }
  if (company && out.text.toLowerCase().includes(company.toLowerCase())) {
    out.violations.push("names_company");
    out.text = out.text.replace(new RegExp(String.raw`\s*,?\s*(?:with|at|from|of)\s+${escapeRe(company)}`, "gi"), "");
    out.text = out.text.replace(new RegExp(escapeRe(company), "gi"), owner);
  }
  if (/post\s?cards?/i.test(out.text)) {
    out.violations.push("mentions_postcard");
    out.text = out.text.replace(/\bpost\s?card(s?)\b/gi, "letter$1");
  }
  out.text = out.text.replace(/\s+/g, " ").trim();
  if (out.text.length > max) {
    out.violations.push("too_long");
    out.text = trim(out.text, max);
  }
  if (!out.text) out.violations.push("empty");
  return out;
}

// Pull "message" out of the model's reply (a JSON object, possibly fenced). null when unreadable.
export function parseModelMessage(raw: string): string | null {
  let text = (raw ?? "").trim().replace(/^```(?:json)?\s*|\s*```$/g, "");
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start < 0 || end <= start) return null;
  text = text.slice(start, end + 1);
  try {
    const data = JSON.parse(text);
    return data && typeof data.message === "string" ? data.message : null;
  } catch {
    return null;
  }
}
