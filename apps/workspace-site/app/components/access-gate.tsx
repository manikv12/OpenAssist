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
    <main className="grid min-h-screen place-items-center bg-[radial-gradient(ellipse_120%_60%_at_50%_-20%,rgba(224,188,99,0.045),transparent_70%),#10131a] px-5 py-10 text-[#e8eef7]">
      <section className="w-full max-w-sm">
        <div className="flex items-center gap-3">
          <img src="/openassist-logo.svg" alt="" width="36" height="36" className="h-9 w-9" />
          <div>
            <p className="font-semibold leading-tight">OpenAssist</p>
            <p className="text-xs leading-tight text-[#7c8a9c]">Daily Workspace</p>
          </div>
        </div>

        <h1 className="mt-8 text-xl font-semibold tracking-[-0.02em]">Sign in</h1>

        <form onSubmit={signInJudge} className="mt-5 space-y-3">
          <label className="block"><span className="sr-only">Judge username</span><input value={username} onChange={(event) => setUsername(event.target.value)} autoComplete="username" placeholder="Judge username" className="w-full rounded-xl border border-white/10 bg-black/20 px-4 py-3 text-sm outline-none transition placeholder:text-[#5b6879] focus:border-[#E0BC63]/50 focus:ring-2 focus:ring-[#E0BC63]/10" /></label>
          <label className="block"><span className="sr-only">Judge access code</span><input type="password" value={code} onChange={(event) => setCode(event.target.value)} autoComplete="current-password" placeholder="Access code" className="w-full rounded-xl border border-white/10 bg-black/20 px-4 py-3 text-sm outline-none transition placeholder:text-[#5b6879] focus:border-[#E0BC63]/50 focus:ring-2 focus:ring-[#E0BC63]/10" /></label>
          {error && <p role="alert" className="text-sm text-[#FFA898]">{error}</p>}
          <button disabled={busy || !username.trim() || !code.trim()} className="w-full rounded-xl bg-[#E0BC63] px-5 py-3 text-sm font-semibold text-[#17130a] transition hover:bg-[#F0CF7A] disabled:cursor-not-allowed disabled:opacity-45">{busy ? 'Checking…' : 'Enter judge demo'}</button>
        </form>

        <div className="my-5 h-px bg-white/[0.08]" />

        <a href={ownerSignInPath} className="block rounded-xl border border-white/[0.09] px-4 py-3 text-sm font-medium transition hover:border-white/20">{ownerButtonLabel}</a>
        {signedInEmail && <p className="mt-3 text-xs text-[#667480]">Signed in as {signedInEmail}</p>}
      </section>
    </main>
  );
}
