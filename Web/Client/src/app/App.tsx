import { DirectionProvider, MantineProvider } from '@mantine/core'
import { ModalsProvider } from '@mantine/modals'
import { Notifications } from '@mantine/notifications'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createBrowserRouter, Navigate, RouterProvider } from 'react-router'
import { RequireAdmin, RequireSession } from '../layout/guards'
import { Shell } from '../layout/Shell'
import { AccountsPage } from '../pages/accounts/AccountsPage'
import { AnnouncementsPage } from '../pages/admin/AnnouncementsPage'
import { ShiftNoticesPage } from '../pages/notices/ShiftNoticesPage'
import { TemplateReportPage } from '../pages/history/TemplateReportPage'
import { TickerReportPage } from '../pages/history/TickerReportPage'
import { WorkSummaryPage } from '../pages/history/WorkSummaryPage'
import { HandoverReportsPage } from '../pages/history/HandoverReportsPage'
import { BulletinReportPage } from '../pages/history/BulletinReportPage'
import { ShiftHistoryPage } from '../pages/history/ShiftHistoryPage'
import { AdminOverviewPage } from '../pages/admin/AdminOverviewPage'
import { TelegramAccessPage } from '../pages/admin/TelegramAccessPage'
import { ScheduleExecutionPage } from '../pages/schedule/ScheduleExecutionPage'
import { TemplateSchedulePage } from '../pages/schedule/TemplateSchedulePage'
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
      { path: 'schedule/executions', element: <ScheduleExecutionPage /> },
      { path: 'schedule', element: <TemplateSchedulePage /> },
      { path: 'newsroom', element: <NewsroomPage /> },
      { path: 'sessions', element: <SessionsPage /> },
      { path: 'notices', element: <ShiftNoticesPage /> },
      { path: 'admin/announcements', element: <RequireAdmin><AnnouncementsPage /></RequireAdmin> },
      { path: 'reports/work-summary', element: <WorkSummaryPage /> },
      { path: 'reports/handover', element: <HandoverReportsPage view="handover" /> },
      { path: 'reports/weekly', element: <HandoverReportsPage view="weekly" /> },
      { path: 'reports/templates', element: <TemplateReportPage /> },
      { path: 'reports/ticker', element: <TickerReportPage /> },
      { path: 'reports/bulletins', element: <BulletinReportPage /> },
      { path: 'history', element: <ShiftHistoryPage /> },
      { path: 'admin/overview', element: <RequireAdmin><AdminOverviewPage /></RequireAdmin> },
      { path: 'telegram-access', element: <RequireAdmin><TelegramAccessPage /></RequireAdmin> },
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
