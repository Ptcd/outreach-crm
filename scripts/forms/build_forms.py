"""Build the contract form data the app signs with.

  wb11-2026.pdf      official WB-11 Residential Offer to Purchase, from the DSPS forms
                     library (dsps.wi.gov), optional use 10-1-2026, mandatory 1-1-2027
  recr_709_03.txt    text of Wis. Stat. 709.03 (the Real Estate Condition Report form),
                     from docs.legis.wisconsin.gov (published 10-1-26)

Writes supabase/functions/_shared/wb11Template.generated.ts (the PDF, base64) and
supabase/functions/_shared/recrForm.generated.ts (the condition report questions).

    python scripts/forms/build_forms.py
"""
import base64
import json
import re
from pathlib import Path

HERE = Path(__file__).parent
OUT = HERE.parent.parent / "supabase" / "functions" / "_shared"

NOISE = re.compile(
    r"^(2023-24 Wisconsin Statutes|stances Board Orders|ter October 1, 2026|Updated |DISCLOSURES BY OWNERS"
    r"|709\.03$|\d+$|\d+\s+Updated|\d+\s+709\.03|YES$|NO$|N/A$|\.\.\.\.\s*$|History:)")


def clean_lines(raw: str) -> list[str]:
    out = []
    for ln in raw.splitlines():
        s = ln.strip()
        if not s or NOISE.match(s):
            continue
        out.append(s)
    return out


def join(lines: list[str]) -> str:
    text = ""
    for s in lines:
        if text.endswith("-") and not text.endswith(" -") and s[:1].islower():
            text = text[:-1] + s
        else:
            text = (text + " " + s).strip()
    text = re.sub(r"\s+", " ", text)
    text = text.replace("https://www.rev- enue.wi.gov", "https://www.revenue.wi.gov")
    return text


def build_recr() -> dict:
    raw = (HERE / "recr_709_03.txt").read_text(encoding="utf-8")
    # stop before the annotations that follow the form
    raw = raw.split("History:")[0]
    lines = clean_lines(raw)
    start = lines.index("A.  OWNER’S INFORMATION") if "A.  OWNER’S INFORMATION" in lines else next(
        i for i, s in enumerate(lines) if s.startswith("A.") and "OWNER" in s)
    preamble = lines[:start]
    body = lines[start:]

    sections = []
    cur = None
    item = None
    cert_at = next(i for i, s in enumerate(body) if s.startswith("OWNER’S CERTIFICATION"))
    for s in body[:cert_at]:
        m_sec = re.match(r"^([A-G])\.\s+([A-Z][A-Z ,.’'&]+)$", s)
        m_item = re.match(r"^([A-G]\d+m?)\.(\s+.*)?$", s)
        m_sub = re.match(r"^([abc])\.\s+(.+)$", s)
        if m_sec:
            cur = {"id": m_sec.group(1), "title": m_sec.group(2).strip(), "intro": [], "items": []}
            sections.append(cur)
            item = None
            continue
        if m_item:
            item = {"id": m_item.group(1), "lines": [(m_item.group(2) or "").strip()] if m_item.group(2) else []}
            cur["items"].append(item)
            continue
        if m_sub and item is not None and item["id"].startswith("F10"):
            item = {"id": "F10" + m_sub.group(1), "lines": [m_sub.group(2)], "sub": True}
            cur["items"].append(item)
            continue
        if item is None:
            cur["intro"].append(s)
        else:
            item["lines"].append(s)

    out_sections = []
    for sec in sections:
        items = []
        for it in sec["items"]:
            text = join(it["lines"])
            if sec["id"] == "A" or it["id"] == "F10":
                items.append({"id": it["id"], "kind": "note", "text": text})
                continue
            if text.startswith("Explanation of"):
                items.append({"id": it["id"], "kind": "explain", "text": "Explanation of “yes” responses"})
                continue
            if it["id"] in ("G6", "G7"):
                items.append({"id": it["id"], "kind": "years", "text": text.replace(".... years", "___ years")})
                continue
            q = text
            hint = ""
            qm = text.find("?")
            if qm >= 0 and qm + 1 < len(text):
                q, hint = text[: qm + 1].strip(), text[qm + 1:].strip()
                # a parenthetical straight after the question belongs to it
                if hint.startswith("("):
                    close = hint.find(")")
                    q, hint = (q + " " + hint[: close + 1]).strip(), hint[close + 1:].strip()
            items.append({"id": it["id"], "kind": "ynna", "text": q, **({"hint": hint} if hint else {})})
        out_sections.append({"id": sec["id"], "title": sec["title"], "intro": join(sec["intro"]) if sec["intro"] else "", "items": items})

    tail = body[cert_at:]
    cert = join(tail[1: next(i for i, s in enumerate(tail) if s.startswith("Owner ....") or s.startswith("Owner ."))])
    buyer_at = next(i for i, s in enumerate(tail) if s.startswith("BUYER’S ACKNOWLEDGEMENT"))
    buyer = join([s for s in tail[buyer_at + 1:] if not s.startswith("Prospective buyer")])
    return {
        "source": "Wis. Stat. 709.03 (published 10-1-26)",
        "preamble": join(preamble[preamble.index("REAL ESTATE CONDITION REPORT") + 1:]) if "REAL ESTATE CONDITION REPORT" in preamble else "",
        "sections": out_sections,
        "certification": cert,
        "buyerAck": buyer,
    }


def main() -> None:
    pdf = (HERE / "wb11-2026.pdf").read_bytes()
    (OUT / "wb11Template.generated.ts").write_text(
        "// Official WB-11 Residential Offer to Purchase (Wisconsin REEB, optional use 10-1-2026, mandatory 1-1-2027),\n"
        "// from dsps.wi.gov. Generated by scripts/forms/build_forms.py; do not edit.\n"
        'export const WB11_VERSION = "WB-11 10-1-2026"\n'
        f'export const WB11_B64 =\n  "{base64.b64encode(pdf).decode()}"\n', encoding="utf-8", newline="\n")
    recr = build_recr()
    (OUT / "recrForm.generated.ts").write_text(
        "// Real Estate Condition Report, Wis. Stat. 709.03. Generated by scripts/forms/build_forms.py; do not edit.\n"
        "export type RecrItem = { id: string; kind: 'ynna' | 'explain' | 'years' | 'note'; text: string; hint?: string }\n"
        "export type RecrSection = { id: string; title: string; intro: string; items: RecrItem[] }\n"
        "export const RECR: { source: string; preamble: string; sections: RecrSection[]; certification: string; buyerAck: string } =\n"
        + json.dumps(recr, indent=1, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")
    n = sum(1 for s in recr["sections"] for i in s["items"] if i["kind"] == "ynna")
    print(f"WB-11 {len(pdf)} bytes; RECR {len(recr['sections'])} sections, {n} yes/no/N-A questions")


if __name__ == "__main__":
    main()
