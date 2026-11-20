/** 0:07, 12:05, 1:02:05 - the on-air counter. Negative clamps to zero. */
export function formatClock(milliseconds: number): string {
  const total = Math.max(0, Math.floor(milliseconds / 1000))
  const hours = Math.floor(total / 3600)
  const minutes = Math.floor((total % 3600) / 60)
  const seconds = total % 60
  const two = (n: number) => String(n).padStart(2, '0')
  return hours > 0 ? `${hours}:${two(minutes)}:${two(seconds)}` : `${minutes}:${two(seconds)}`
}

/** "منذ 3 د" style, for last-seen columns. */
export function formatAgo(milliseconds: number): string {
  const seconds = Math.max(0, Math.round(milliseconds / 1000))
  if (seconds < 45) return 'الآن'
  const minutes = Math.round(seconds / 60)
  if (minutes < 60) return `منذ ${minutes} د`
  const hours = Math.round(minutes / 60)
  if (hours < 48) return `منذ ${hours} س`
  return `منذ ${Math.round(hours / 24)} يوم`
}

const dateTime = new Intl.DateTimeFormat('ar', {
  dateStyle: 'medium',
  timeStyle: 'short',
  numberingSystem: 'latn',
})

export function formatDateTime(value: string | number | null | undefined): string {
  if (value === null || value === undefined || value === 0) return '—'
  return dateTime.format(new Date(value))
}

export function localDateInput(date: Date): string {
  return new Date(date.getTime() - date.getTimezoneOffset() * 60_000).toISOString().slice(0, 16)
}

/**
 * Whether the bridge's last Cinegy reading still counts. A counter running on
 * an unconfirmed reading would claim more than the bridge knows - the same
 * rule the Telegram card follows.
 */
export function isFresh(freshUntil: number, now: number): boolean {
  return freshUntil > 0 && now < freshUntil
}
