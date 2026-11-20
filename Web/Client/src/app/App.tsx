import { DirectionProvider, MantineProvider } from '@mantine/core'
import { ModalsProvider } from '@mantine/modals'
import { Notifications } from '@mantine/notifications'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createBrowserRouter, Navigate, RouterProvider } from 'react-router'
import { RequireAdmin, RequireSession } from '../layout/guards'
import { Shell } from '../layout/Shell'
import { AccountsPage } from '../pages/accounts/AccountsPage'
import { LoginPage } from '../pages/login/LoginPage'
import { NewsroomPage } from '../pages/newsroom/NewsroomPage'
import { SessionsPage } from '../pages/sessions/SessionsPage'
import { StatusPage } from '../pages/status/StatusPage'
import { TemplatesPage } from '../pages/templates/TemplatesPage'
import { theme } from './theme'

const queryClient = new QueryClient({
  defaultOptions: {
    queries: { retry: 1, refetchOnWindowFocus: true },
  },
})

const router = createBrowserRouter([
  { path: '/login', element: <LoginPage /> },
  {
    element: (
      <RequireSession>
        <Shell />
      </RequireSession>
    ),
    children: [
      { index: true, element: <Navigate to="/newsroom" replace /> },
      { path: 'air', element: <StatusPage /> },
      { path: 'live', element: <></> },
      { path: 'templates', element: <TemplatesPage /> },
      { path: 'newsroom', element: <NewsroomPage /> },
      { path: 'sessions', element: <SessionsPage /> },
      {
        path: 'accounts',
        element: (
          <RequireAdmin>
            <AccountsPage />
          </RequireAdmin>
        ),
      },
    ],
  },
  { path: '*', element: <Navigate to="/" replace /> },
])

export function App() {
  return (
    <DirectionProvider initialDirection="rtl" detectDirection={false}>
      <MantineProvider theme={theme} defaultColorScheme="light">
        <QueryClientProvider client={queryClient}>
          <ModalsProvider labels={{ confirm: 'تأكيد', cancel: 'إلغاء' }}>
            <Notifications position="bottom-left" />
            <RouterProvider router={router} />
          </ModalsProvider>
        </QueryClientProvider>
      </MantineProvider>
    </DirectionProvider>
  )
}
