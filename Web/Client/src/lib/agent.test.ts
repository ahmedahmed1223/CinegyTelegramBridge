import { describe, expect, it } from 'vitest'
import { describeAgent } from './agent'

describe('describeAgent', () => {
  it('names Edge as Edge, not as the Chrome it also claims to be', () => {
    const edge = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36 Edg/140.0'
    expect(describeAgent(edge)).toBe('Edge على Windows')
  })

  it('reads a phone', () => {
    const iphone = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1'
    expect(describeAgent(iphone)).toBe('Safari على iOS')
  })

  it('says unknown for nothing', () => {
    expect(describeAgent('')).toBe('غير معروف')
  })
})
