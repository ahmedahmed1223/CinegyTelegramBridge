import { createTheme, type MantineColorsTuple } from '@mantine/core'

const signal: MantineColorsTuple = [
  '#e6f8f5', '#ccefe8', '#a5e2d8', '#7bd2c4', '#58c4b3',
  '#39af9d', '#08776a', '#09675d', '#085449', '#073d36',
]

const ink: MantineColorsTuple = [
  '#f3f6fa', '#e4eaf1', '#d1dbe7', '#b7c6d6', '#94a6bc',
  '#788da6', '#5a708b', '#415773', '#2d405b', '#162439',
]

export const theme = createTheme({
  primaryColor: 'signal',
  primaryShade: 6,
  autoContrast: true,
  colors: {
    signal,
    ink,
    dark: ['#e1e8f1', '#b0bed0', '#8e9fb6', '#6d809c', '#4c607d', '#354860', '#263850', '#1a2a40', '#132137', '#0d1828'],
  },
  fontFamily: "'IBM Plex Sans Arabic', system-ui, sans-serif",
  fontFamilyMonospace: "'IBM Plex Mono', 'IBM Plex Sans Arabic', ui-monospace, monospace",
  headings: {
    fontFamily: "'IBM Plex Sans Arabic', system-ui, sans-serif",
    fontWeight: '700',
  },
  defaultRadius: 'md',
  radius: { xs: '4px', sm: '7px', md: '9px', lg: '15px', xl: '22px' },
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
