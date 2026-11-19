import { createTheme, type MantineColorsTuple } from '@mantine/core'

// Direction: a broadcast control room. Quiet ink surfaces so the only loud
// colour on screen is the one that means something - red for on air, green
// for healthy, amber for unconfirmed. The brand blue stays out of their way.
const signal: MantineColorsTuple = [
  '#e8f3ff', '#d2e3fb', '#a4c4f2', '#72a3ea', '#4a87e3',
  '#3075e0', '#216cdf', '#125bc7', '#0450b3', '#00459f',
]

const ink: MantineColorsTuple = [
  '#f3f5f7', '#e4e8ec', '#c7cfd7', '#a7b3bf', '#8c9aa8',
  '#7a8a9a', '#6f8193', '#5d6e80', '#2a333d', '#12171d',
]

export const theme = createTheme({
  primaryColor: 'signal',
  primaryShade: { light: 6, dark: 5 },
  colors: {
    signal,
    ink,
    // Mantine's dark scale drives every dark surface; this one leans cool.
    dark: ['#c9d1d9', '#aab4bf', '#7d8995', '#56616d', '#3a434d', '#2a323b', '#1f262e', '#171d23', '#12171c', '#0d1115'],
  },
  fontFamily: "'IBM Plex Sans Arabic', system-ui, sans-serif",
  fontFamilyMonospace: "'JetBrains Mono Variable', ui-monospace, monospace",
  headings: {
    fontFamily: "'IBM Plex Sans Arabic', system-ui, sans-serif",
    fontWeight: '600',
  },
  defaultRadius: 'md',
  radius: { xs: '4px', sm: '6px', md: '10px', lg: '14px', xl: '20px' },
  components: {
    Paper: { defaultProps: { withBorder: true } },
    Card: { defaultProps: { withBorder: true } },
    Button: { defaultProps: { fw: 600 } },
    Tooltip: { defaultProps: { withArrow: true, openDelay: 250 } },
    // Mantine's own label is English; screen readers here speak Arabic.
    PasswordInput: { defaultProps: { visibilityToggleButtonProps: { 'aria-label': 'إظهار كلمة المرور أو إخفاؤها' } } },
    Modal: { defaultProps: { closeButtonProps: { 'aria-label': 'إغلاق' } } },
  },
})
