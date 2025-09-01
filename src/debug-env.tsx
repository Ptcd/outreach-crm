// Debug page to check environment variables
export default function DebugEnv() {
  return (
    <div style={{ padding: '20px', fontFamily: 'monospace' }}>
      <h1>Environment Variables Debug</h1>
      <p>VITE_SUPABASE_URL: {import.meta.env.VITE_SUPABASE_URL || 'MISSING'}</p>
      <p>VITE_SUPABASE_ANON_KEY: {import.meta.env.VITE_SUPABASE_ANON_KEY ? 'SET' : 'MISSING'}</p>
      <h2>All Environment Variables:</h2>
      <pre>{JSON.stringify(import.meta.env, null, 2)}</pre>
    </div>
  )
}
