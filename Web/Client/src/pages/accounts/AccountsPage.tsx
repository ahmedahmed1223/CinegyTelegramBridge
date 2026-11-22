import { ActionIcon, Alert, Badge, Button, Group, Menu, Paper, Skeleton, Stack, Table, Text } from '@mantine/core'
import { useDisclosure } from '@mantine/hooks'
import { modals } from '@mantine/modals'
import { notifications } from '@mantine/notifications'
import { IconDots, IconKey, IconLock, IconPlus, IconTrash } from '@tabler/icons-react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { roleLabel, useSession } from '../../api/session'
import { PageHeader } from '../../components/PageHeader'
import { useNow } from '../../hooks/useNow'
import { formatDateTime } from '../../lib/time'
import { CreateAccountModal } from './CreateAccountModal'
import { ResetPasswordModal } from './ResetPasswordModal'

type Account = Schemas['WebAccountResponse']
const accountsKey = ['accounts'] as const

export function AccountsPage() {
  const session = useSession()
  const queryClient = useQueryClient()
  const [createOpen, create] = useDisclosure()
  const [resetting, setResetting] = useState<Account | null>(null)
  const now = useNow(30_000)
  const accounts = useQuery({
    queryKey: accountsKey,
    queryFn: async () => {
      const { data, error, response } = await api.GET('/api/accounts')
      if (!data) throw new Error(messageFor(errorCode(error, response)))
      return data
    },
  })
  const isOwner = session.data?.role === 'owner'

  function confirmDelete(account: Account) {
    modals.openConfirmModal({
      title: 'حذف حساب الويب',
      centered: true,
      children: (
        <Text size="sm">
          {account.webOnly
            ? `سيُحذف حساب «${account.displayName}» ويفقد صلاحيته في الجسر كله، وتُنهى جلساته المفتوحة.`
            : `ستُحذف كلمة مرور «${account.displayName}» للويب. حسابه في البوت يبقى كما هو، ويستطيع الدخول عبر Telegram.`}
        </Text>
      ),
      labels: { confirm: 'حذف', cancel: 'إلغاء' },
      confirmProps: { color: 'red' },
      onConfirm: async () => {
        const { error, response } = await api.DELETE('/api/accounts/{username}', { params: { path: { username: account.username } } })
        if (response.ok) {
          notifications.show({ color: 'green', message: 'حُذف الحساب.' })
          await queryClient.invalidateQueries({ queryKey: accountsKey })
        } else {
          notifications.show({ color: 'red', message: messageFor(errorCode(error, response)) })
        }
      },
    })
  }

  return (
    <Stack gap="lg">
      <PageHeader title="الحسابات" description="إدارة حسابات الويب وكلمات المرور والصلاحيات." actions={
        <Button leftSection={<IconPlus size={18} />} onClick={create.open} disabled={!accounts.data}>
          حساب جديد
        </Button>
      } />

      {accounts.isError && <Alert color="red">{accounts.error.message}</Alert>}

      <Paper radius="lg" p={0} style={{ overflow: 'hidden' }}>
        {accounts.isPending ? (
          <Stack p="lg">
            <Skeleton h={20} />
            <Skeleton h={20} />
            <Skeleton h={20} />
          </Stack>
        ) : accounts.data && accounts.data.accounts.length === 0 ? (
          <Stack p="xl" align="center" gap={4}>
            <Text fw={600}>لا حسابات بكلمة مرور بعد</Text>
            <Text size="sm" c="dimmed">
              من في البوت يدخل عبر Telegram دون حساب هنا. أضف حسابًا لمن يحتاج كلمة مرور، أو لشخص بلا Telegram.
            </Text>
          </Stack>
        ) : (
          <Table.ScrollContainer minWidth={720}>
            <Table verticalSpacing="sm" horizontalSpacing="lg" highlightOnHover style={{ whiteSpace: 'nowrap' }}>
              <Table.Thead>
                <Table.Tr>
                  <Table.Th>الاسم</Table.Th>
                  <Table.Th>اسم المستخدم</Table.Th>
                  <Table.Th>النوع</Table.Th>
                  <Table.Th>الدور</Table.Th>
                  <Table.Th>آخر دخول</Table.Th>
                  <Table.Th w={48} />
                </Table.Tr>
              </Table.Thead>
              <Table.Tbody>
                {accounts.data?.accounts.map((account) => {
                  const protectedAccount = (account.role === 'admin' || account.role === 'owner') && !isOwner
                  const locked = account.lockedUntil && Date.parse(account.lockedUntil) > now
                  return (
                    <Table.Tr key={account.username}>
                      <Table.Td>
                        <Group gap={6}>
                          <Text fw={600}>{account.displayName}</Text>
                          {locked && (
                            <Badge color="orange" variant="light" leftSection={<IconLock size={12} />}>
                              مقفل
                            </Badge>
                          )}
                        </Group>
                      </Table.Td>
                      <Table.Td>
                        <Text size="sm" className="cgb-mono" span>
                          {account.username}
                        </Text>
                      </Table.Td>
                      <Table.Td>
                        <Badge variant="light" color={account.webOnly ? 'grape' : 'signal'}>
                          {account.webOnly ? 'ويب فقط' : 'مرتبط بـ Telegram'}
                        </Badge>
                      </Table.Td>
                      <Table.Td>
                        <Badge variant="default">{roleLabel[account.role] ?? account.role}</Badge>
                      </Table.Td>
                      <Table.Td>
                        <Text size="sm" c="dimmed">
                          {formatDateTime(account.lastLoginAt)}
                        </Text>
                      </Table.Td>
                      <Table.Td>
                        <Menu position="bottom-end" withinPortal>
                          <Menu.Target>
                            <ActionIcon variant="subtle" color="gray" aria-label={`إجراءات ${account.displayName}`}>
                              <IconDots size={18} />
                            </ActionIcon>
                          </Menu.Target>
                          <Menu.Dropdown>
                            {protectedAccount && <Menu.Label>حسابات المشرفين يديرها المالك</Menu.Label>}
                            <Menu.Item leftSection={<IconKey size={16} />} disabled={protectedAccount} onClick={() => setResetting(account)}>
                              كلمة مرور جديدة
                            </Menu.Item>
                            <Menu.Item color="red" leftSection={<IconTrash size={16} />} disabled={protectedAccount} onClick={() => confirmDelete(account)}>
                              حذف
                            </Menu.Item>
                          </Menu.Dropdown>
                        </Menu>
                      </Table.Td>
                    </Table.Tr>
                  )
                })}
              </Table.Tbody>
            </Table>
          </Table.ScrollContainer>
        )}
      </Paper>

      {accounts.data && (
        <CreateAccountModal
          opened={createOpen}
          onClose={create.close}
          bridgeUsers={accounts.data.bridgeUsers}
          canCreateAdmin={isOwner}
          onCreated={() => queryClient.invalidateQueries({ queryKey: accountsKey })}
        />
      )}
      <ResetPasswordModal
        account={resetting}
        onClose={() => setResetting(null)}
        onReset={() => void queryClient.invalidateQueries({ queryKey: accountsKey })}
      />
    </Stack>
  )
}
