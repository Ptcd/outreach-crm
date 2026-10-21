// A minimal SMTP client for one plain message (Gmail, implicit TLS on port 465: Supabase Edge
// Functions may not open port 587 or 25). The connection is injected so tests drive it with a
// fake server; the Edge Function passes Deno.connectTls.

export interface SmtpConn {
  write(data: Uint8Array): Promise<number>
  read(buf: Uint8Array): Promise<number | null>
  close(): void
}
export interface Mail { from: string; to: string; subject: string; text: string; html: string }
export interface SmtpAuth { user: string; pass: string }

const enc = new TextEncoder()
const dec = new TextDecoder()

function b64(s: string): string {
  let bin = ''
  for (const b of enc.encode(s)) bin += String.fromCharCode(b)
  return btoa(bin)
}

/** base64 body wrapped at 76 columns. */
function b64Body(s: string): string {
  return (b64(s).match(/.{1,76}/g) ?? []).join('\r\n')
}

export function buildMessage(m: Mail, now = new Date(), boundary = `wpie${now.getTime().toString(36)}`): string {
  return [
    `From: WPIE <${m.from}>`,
    `To: <${m.to}>`,
    `Subject: =?UTF-8?B?${b64(m.subject)}?=`,
    `Date: ${now.toUTCString()}`,
    'MIME-Version: 1.0',
    `Content-Type: multipart/alternative; boundary="${boundary}"`,
    '',
    `--${boundary}`,
    'Content-Type: text/plain; charset=UTF-8',
    'Content-Transfer-Encoding: base64',
    '',
    b64Body(m.text),
    `--${boundary}`,
    'Content-Type: text/html; charset=UTF-8',
    'Content-Transfer-Encoding: base64',
    '',
    b64Body(m.html),
    `--${boundary}--`,
    '',
  ].join('\r\n')
}

export async function sendMail(conn: SmtpConn, auth: SmtpAuth, m: Mail): Promise<void> {
  let pending = ''
  const buf = new Uint8Array(4096)
  async function reply(expect: number): Promise<string> {
    for (;;) {
      const lines = pending.split('\r\n')
      for (let i = 0; i < lines.length - 1; i++) {
        if (/^\d{3} /.test(lines[i])) {
          const code = Number(lines[i].slice(0, 3))
          pending = lines.slice(i + 1).join('\r\n')
          if (code !== expect) throw new Error(`SMTP ${code}: ${lines[i].slice(4, 120)}`)
          return lines[i]
        }
      }
      const n = await conn.read(buf)
      if (n === null) throw new Error('SMTP connection closed')
      pending += dec.decode(buf.subarray(0, n))
    }
  }
  const send = (s: string) => conn.write(enc.encode(s + '\r\n'))
  try {
    await reply(220)
    await send('EHLO wpie'); await reply(250)
    await send('AUTH LOGIN'); await reply(334)
    await send(b64(auth.user)); await reply(334)
    await send(b64(auth.pass)); await reply(235)
    await send(`MAIL FROM:<${m.from}>`); await reply(250)
    await send(`RCPT TO:<${m.to}>`); await reply(250)
    await send('DATA'); await reply(354)
    const body = buildMessage(m).split('\r\n').map((l) => (l.startsWith('.') ? '.' + l : l)).join('\r\n')
    await conn.write(enc.encode(body + '\r\n.\r\n')); await reply(250)
    await send('QUIT')
  } finally {
    conn.close()
  }
}
