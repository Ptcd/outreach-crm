// A minimal SMTP client for one plain message (Gmail, implicit TLS on port 465: Supabase Edge
// Functions may not open port 587 or 25). The connection is injected so tests drive it with a
// fake server; the Edge Function passes Deno.connectTls.

export interface SmtpConn {
  write(data: Uint8Array): Promise<number>
  read(buf: Uint8Array): Promise<number | null>
  close(): void
}
export interface Attachment { filename: string; contentType: string; bytes: Uint8Array }
export interface Mail {
  from: string; to: string; subject: string; text: string; html: string
  fromName?: string            // shown as the sender; "WPIE" when not given
  replyTo?: string
  attachments?: Attachment[]   // sent as multipart/mixed around the text + html
}
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

/** Bytes as base64 wrapped at 76 columns (57 bytes a line), built in chunks so a 1 MB PDF does not blow the stack. */
function b64Bytes(bytes: Uint8Array): string {
  const lines: string[] = []
  for (let i = 0; i < bytes.length; i += 57) lines.push(btoa(String.fromCharCode(...bytes.subarray(i, i + 57))))
  return lines.join('\r\n')
}

const plain = (s: string) => s.replace(/["\\\r\n<>]/g, '').trim()
const word = (s: string) => (/^[\x20-\x7e]*$/.test(s) ? `"${s}"` : `=?UTF-8?B?${b64(s)}?=`)

export function buildMessage(m: Mail, now = new Date(), boundary = `wpie${now.getTime().toString(36)}`): string {
  const name = plain(m.fromName ?? '')
  const head = [
    `From: ${name ? word(name) : 'WPIE'} <${m.from}>`,
    `To: <${m.to}>`,
    ...(m.replyTo ? [`Reply-To: <${plain(m.replyTo)}>`] : []),
    `Subject: =?UTF-8?B?${b64(m.subject)}?=`,
    `Date: ${now.toUTCString()}`,
    'MIME-Version: 1.0',
  ]
  const alt = [
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
  ]
  if (!m.attachments?.length) {
    return [...head, `Content-Type: multipart/alternative; boundary="${boundary}"`, '', ...alt, ''].join('\r\n')
  }
  const mixed = `${boundary}x`
  return [
    ...head,
    `Content-Type: multipart/mixed; boundary="${mixed}"`,
    '',
    `--${mixed}`,
    `Content-Type: multipart/alternative; boundary="${boundary}"`,
    '',
    ...alt,
    ...m.attachments.flatMap((a) => {
      const fn = plain(a.filename).replace(/[^\x20-\x7e]/g, '_') || 'file'
      return [
        `--${mixed}`,
        `Content-Type: ${plain(a.contentType)}; name="${fn}"`,
        'Content-Transfer-Encoding: base64',
        `Content-Disposition: attachment; filename="${fn}"`,
        '',
        b64Bytes(a.bytes),
      ]
    }),
    `--${mixed}--`,
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
  // a socket write may take only part of a large message (a PDF attachment): keep going until it is all sent
  const writeAll = async (bytes: Uint8Array) => {
    let off = 0
    while (off < bytes.length) {
      const n = await conn.write(bytes.subarray(off))
      if (!n) throw new Error('SMTP connection stopped taking data')
      off += n
    }
  }
  const send = (s: string) => writeAll(enc.encode(s + '\r\n'))
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
    await writeAll(enc.encode(body + '\r\n.\r\n')); await reply(250)
    await send('QUIT')
  } finally {
    conn.close()
  }
}
