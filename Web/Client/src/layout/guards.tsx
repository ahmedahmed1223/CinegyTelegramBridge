import { Button, Center, Loader, Stack, Text } from '@mantine/core'
import type { ReactNode } from 'react'
import { Navigate } from 'react-router'
import { isAdmin, useSession } from '../api/session'

export function RequireSession({ children }: { children: ReactNode }) {
  const session = useSession()
  if (session.isPending) {
    return (
      <Center h="100vh">
        <Loader />
      </Center>
    )
  }
  if (session.isError) {
    return (
      <Center h="100vh">
        <Stack align="center" gap="sm">
          <Text fw={600}>تعذّر الوصول إلى خادم الويب.</Text>
          <Button variant="light" onClick={() => session.refetch()}>
            إعادة المحاولة
          </Button>
        </Stack>
      </Center>
    )
  }
  if (!session.data) return <Navigate to="/login" replace />
  return children
}

export function RequireAdmin({ children }: { children: ReactNode }) {
  const session = useSession()
  return isAdmin(session.data) ? children : <Navigate to="/" replace />
}
