// The public privacy page the Google consent screen links to (WPIE Calendar, 2026-10-26). No login.
export default function Privacy() {
  return (
    <div className="mx-auto max-w-2xl space-y-4 p-6 text-base leading-relaxed">
      <h1 className="text-2xl font-bold">Privacy</h1>
      <p>
        This app is Colin Merrill's private work tool for buying houses in Wisconsin. Only Colin and the people who work with him sign in to it.
      </p>
      <h2 className="text-lg font-semibold">Google Calendar</h2>
      <p>
        When Colin connects a Google Calendar, the app reads when that calendar is busy, so it only offers sellers times that are open. It also
        adds, reads and removes the events for the calls and visits it books. It does not read the details of other events, and it does not use
        Gmail, Drive or contacts.
      </p>
      <p>
        The access Google grants is kept encrypted on the app's server and is used only for booking. It is never sold, shared or used for
        advertising. Disconnect at any time from the app's Settings, or from your Google Account under Security, Third-party access.
      </p>
      <h2 className="text-lg font-semibold">Sellers</h2>
      <p>
        Property and contact details come from public records and data providers. A seller who asks not to be contacted is never contacted again.
      </p>
    </div>
  )
}
