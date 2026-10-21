// An email Colin or Adil sends from the app (always their tap; never AI-sent). Pure checks and
// the HTML version; reply-send does the sending and logs it on the lead (log_email).

const ADDR = /^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$/i

export function checkEmail(x: { to: string; subject: string; body: string }): string | null {
  if (!ADDR.test((x.to ?? '').trim())) return 'That is not an email address.'
  if (!(x.subject ?? '').trim()) return 'Add a subject.'
  if ((x.subject ?? '').length > 150) return 'The subject is too long.'
  if (!(x.body ?? '').trim()) return 'The email is empty.'
  if ((x.body ?? '').length > 10_000) return 'The email is too long.'
  return null
}

export function bodyHtml(body: string): string {
  const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  return `<div style="font-family:Arial,sans-serif;font-size:15px;line-height:1.5">${body.split(/\n{2,}/).map((p) => `<p>${esc(p).replace(/\n/g, '<br>')}</p>`).join('')}</div>`
}
