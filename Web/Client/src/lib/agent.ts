/** "Edge on Windows" from a user-agent string: enough to recognise a device. */
export function describeAgent(agent: string): string {
  if (!agent) return 'غير معروف'
  const browser =
    /Edg\//.test(agent) ? 'Edge'
    : /OPR\//.test(agent) ? 'Opera'
    : /Firefox\//.test(agent) ? 'Firefox'
    : /Chrome\//.test(agent) ? 'Chrome'
    : /Safari\//.test(agent) ? 'Safari'
    : 'متصفح'
  const system =
    /Windows/.test(agent) ? 'Windows'
    : /iPhone|iPad/.test(agent) ? 'iOS'
    : /Android/.test(agent) ? 'Android'
    : /Mac OS X/.test(agent) ? 'macOS'
    : /Linux/.test(agent) ? 'Linux'
    : ''
  return system ? `${browser} على ${system}` : browser
}
