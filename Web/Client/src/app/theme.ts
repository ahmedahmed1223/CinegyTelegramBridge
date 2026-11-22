import { createTheme, defaultVariantColorsResolver, type MantineColorsTuple } from '@mantine/core'

const signal: MantineColorsTuple = [
  '#eef3fc', '#dde8fb', '#c3d5f5', '#9ab9ee', '#729be3',
  '#4878d0', '#214ea5', '#1c438e', '#183568', '#122748',
]

const navy: MantineColorsTuple = [
  '#f1f5ff', '#d8e3f5', '#b9c9e3', '#94a9ca', '#708ab0',
  '#536e94', '#344b69', '#1a2a42', '#152137', '#101a2c',
]

export const theme = createTheme({
  primaryColor: 'signal',
  primaryShade: { light: 6, dark: 3 },
  autoContrast: true,
  variantColorResolver: (input) => {
    const colors = defaultVariantColorsResolver(input)
    if (input.variant === 'filled' && input.color === input.theme.primaryColor && input.autoContrast !== false) {
      // The fill follows the active scheme, so use that scheme's contrast.
      return { ...colors, color: 'var(--mantine-primary-color-contrast)' }
    }
    return colors
  },
  colors: {
    signal,
    dark: navy,
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
