import { createTheme, type MantineColorsTuple } from '@mantine/core'

const signal: MantineColorsTuple = [
  '#eef3fc', '#dde8fb', '#c3d5f5', '#9ab9ee', '#729be3',
  '#4878d0', '#214ea5', '#1c438e', '#183568', '#122748',
]

export const theme = createTheme({
  primaryColor: 'signal',
  primaryShade: { light: 6, dark: 3 },
  autoContrast: true,
  colors: {
    signal,
    dark: ['#edeee7', '#bfc2bb', '#a1a59c', '#85897f', '#65695f', '#4d5048', '#373a34', '#292b26', '#22241f', '#1b1d19'],
  },
  fontFamily: "'IBM Plex Sans Arabic', system-ui, sans-serif",
  fontFamilyMonospace: "'IBM Plex Mono', 'IBM Plex Sans Arabic', ui-monospace, monospace",
  headings: {
    fontFamily: "'IBM Plex Sans Arabic', system-ui, sans-serif",
    fontWeight: '700',
  },
  defaultRadius: 'md',
  radius: { xs: '3px', sm: '5px', md: '6px', lg: '8px', xl: '12px' },
  components: {
    Paper: { defaultProps: { withBorder: true } },
    Card: { defaultProps: { withBorder: true } },
    Button: { defaultProps: { fw: 600 } },
    Table: { defaultProps: { highlightOnHover: true, withRowBorders: true } },
    Tooltip: { defaultProps: { withArrow: true, openDelay: 250 } },
    // Mantine's own label is English; screen readers here speak Arabic.
    PasswordInput: { defaultProps: { visibilityToggleButtonProps: { 'aria-label': 'إظهار كلمة المرور أو إخفاؤها' } } },
    Modal: { defaultProps: { closeButtonProps: { 'aria-label': 'إغلاق' } } },
  },
})
