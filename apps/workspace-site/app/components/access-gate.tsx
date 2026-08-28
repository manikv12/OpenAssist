'use client';
/* eslint-disable @next/next/no-img-element */

import { useState } from 'react';
import { useRouter } from 'next/navigation';

export function AccessGate({ ownerSignInPath, ownerButtonLabel, signedInEmail }: {
  ownerSignInPath: string;
  ownerButtonLabel: string;
  signedInEmail: string | null;
}) {
  const router = useRouter();
  const [username, setUsername] = useState('');
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function signInJudge(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusy(true);
    setError('');
    try {
      const response = await fetch('/api/judge/login', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ username, code }),
      });
      const body = await response.json() as { error?: string };
      if (!response.ok) throw new Error(body.error ?? 'Judge access could not be verified.');
      router.refresh();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Judge access could not be verified.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="min-h-screen bg-[radial-gradient(circle_at_20%_0%,rgba(224,188,99,0.11),transparent_34%),radial-gradient(circle_at_88%_6%,rgba(83,74,177,0.13),transparent_28%),#08090d] px-5 py-10 text-[#e8eef7] sm:px-8">
      <div className="mx-auto flex min-h-[calc(100vh-5rem)] max-w-5xl items-center justify-center">
        <section className="w-full overflow-hidden rounded-[32px] border border-white/[0.09] bg-[#0c0e12]/95 shadow-[0_40px_120px_rgba(0,0,0,0.48)]">
          <div className="grid lg:grid-cols-[0.9fr_1.1fr]">
            <div className="border-b border-white/[0.08] p-7 sm:p-10 lg:border-b-0 lg:border-r">
              <div className="flex items-center gap-3">
                <img src="/openassist-logo.svg" alt="OpenAssist" width="44" height="44" className="h-11 w-11" />
                <div><p className="font-semibold">OpenAssist</p><p className="text-xs text-[#7c8a9c]">Daily Workspace</p></div>
              </div>
              <p className="mt-12 text-xs font-semibold uppercase tracking-[0.2em] text-[#E0BC63]">Private WebMCP review</p>
              <h1 className="mt-3 text-3xl font-semibold tracking-[-0.04em] sm:text-4xl">One workspace. Two protected entrances.</h1>
              <p className="mt-5 max-w-md text-sm leading-7 text-[#8d9aaa]">Judges receive an isolated synthetic workspace. The owner entrance is the only path to real Google data and administrative controls.</p>
              <div className="mt-8 space-y-3 text-sm text-[#aeb8c5]">
                <p>✓ Judge data expires automatically</p>
                <p>✓ The funded API key stays encrypted and hidden</p>
                <p>✓ Live Workspace remains owner-only</p>
              </div>
            </div>

            <div className="p-7 sm:p-10">
              <div className="rounded-2xl border border-[#E0BC63]/20 bg-[#E0BC63]/[0.045] p-5">
                <p className="text-xs font-semibold uppercase tracking-[0.16em] text-[#E0BC63]">Judge access</p>
                <h2 className="mt-2 text-xl font-semibold">Open the private demo</h2>
                <p className="mt-2 text-sm leading-6 text-[#7c8a9c]">Use the username and access code included in the submission.</p>
                <form onSubmit={signInJudge} className="mt-5 space-y-3">
                  <label className="block"><span className="sr-only">Judge username</span><input value={username} onChange={(event) => setUsername(event.target.value)} autoComplete="username" placeholder="Judge username" className="w-full rounded-xl border border-white/10 bg-black/20 px-4 py-3 text-sm outline-none transition placeholder:text-[#5b6879] focus:border-[#E0BC63]/50 focus:ring-2 focus:ring-[#E0BC63]/10" /></label>
                  <label className="block"><span className="sr-only">Judge access code</span><input type="password" value={code} onChange={(event) => setCode(event.target.value)} autoComplete="current-password" placeholder="Access code" className="w-full rounded-xl border border-white/10 bg-black/20 px-4 py-3 text-sm outline-none transition placeholder:text-[#5b6879] focus:border-[#E0BC63]/50 focus:ring-2 focus:ring-[#E0BC63]/10" /></label>
                  {error && <p role="alert" className="text-sm text-[#FFA898]">{error}</p>}
                  <button disabled={busy || !username.trim() || !code.trim()} className="w-full rounded-xl bg-[#E0BC63] px-5 py-3 text-sm font-semibold text-[#17130a] transition hover:bg-[#F0CF7A] disabled:cursor-not-allowed disabled:opacity-45">{busy ? 'Checking access…' : 'Enter judge demo'}</button>
                </form>
              </div>

              <div className="my-6 flex items-center gap-3 text-[10px] uppercase tracking-[0.16em] text-[#536071]"><span className="h-px flex-1 bg-white/[0.08]" />Owner only<span className="h-px flex-1 bg-white/[0.08]" /></div>

              <a href={ownerSignInPath} className="block rounded-2xl border border-white/[0.09] bg-white/[0.025] p-5 transition hover:border-[#E0BC63]/30 hover:bg-[#E0BC63]/[0.035]">
                <p className="text-sm font-semibold">{ownerButtonLabel}</p>
                <p className="mt-1 text-xs leading-5 text-[#7c8a9c]">Live Google Workspace and owner settings require the exact owner ChatGPT account.</p>
              </a>
              {signedInEmail && <p className="mt-3 text-xs text-[#667480]">Currently signed in as {signedInEmail}</p>}
            </div>
          </div>
        </section>
      </div>
    </main>
  );
}
