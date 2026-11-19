import { useEffect, useState } from 'react'

/** The device clock, re-read every interval. Counters derive from it so the
 *  server sends instants, not ticking text. */
export function useNow(intervalMs = 1000): number {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), intervalMs)
    return () => window.clearInterval(timer)
  }, [intervalMs])
  return now
}
