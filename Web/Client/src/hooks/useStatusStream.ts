import { useEffect, useState } from 'react'
import type { BridgeStatus, StatusEnvelope } from '../api/client'

export type StreamState = 'connecting' | 'live' | 'reconnecting'

export interface LiveStatus {
  /** The server's link to us: is the event stream open? */
  stream: StreamState
  /** The bridge's link to the server: did its last read succeed? */
  bridgeOnline: boolean
  status: BridgeStatus | null
}

/**
 * The bridge's state, pushed by the server once a second over server-sent
 * events. EventSource reconnects on its own; this only reports whether it is
 * connected, so the page can say so instead of showing a frozen picture.
 */
export function useStatusStream(): LiveStatus {
  const [live, setLive] = useState<LiveStatus>({ stream: 'connecting', bridgeOnline: false, status: null })

  useEffect(() => {
    const source = new EventSource('/api/status/stream')
    source.addEventListener('status', (event) => {
      const envelope = JSON.parse((event as MessageEvent<string>).data) as StatusEnvelope
      setLive((previous) => ({
        stream: 'live',
        bridgeOnline: envelope.online,
        // Keep the last picture while the bridge is away; the page marks it stale.
        status: envelope.status ?? previous.status,
      }))
    })
    source.onerror = () => setLive((previous) => ({ ...previous, stream: 'reconnecting' }))
    return () => source.close()
  }, [])

  return live
}
