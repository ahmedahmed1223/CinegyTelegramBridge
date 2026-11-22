import { ActionIcon, Alert, Badge, Button, Group, Menu, NativeSelect, Paper, SimpleGrid, Skeleton, Stack, Table, Text, TextInput } from '@mantine/core'
import { useDisclosure } from '@mantine/hooks'
import { modals } from '@mantine/modals'
import { notifications } from '@mantine/notifications'
import { IconDots, IconKey, IconLock, IconPlus, IconRefresh, IconSearch, IconTrash } from '@tabler/icons-react'
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
const accountNames = new Intl.Collator('ar', { sensitivity: 'base', numeric: true })
const number = new Intl.NumberFormat('ar')
const normalize = (value: string) => value.normalize('NFKD').replace(/[\p{M}\u0640]/gu, '').toLowerCase().trim()

export function AccountsPage() {
  const session = useSession()
  const queryClient = useQueryClient()
  const [createOpen, create] = useDisclosure()
  const [resetting, setResetting] = useState<Account | null>(null)
  const [deleting, setDeleting] = useState(false)
  const [search, setSearch] = useState('')
  const [role, setRole] = useState('')
  const [sort, setSort] = useState('name')
  const now = useNow(30_000)
  const accounts = useQuery({
    queryKey: accountsKey,
    retry: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/accounts', { signal }).catch(() => {
        throw new Error(messageFor('bridge_unavailable'))
      })
      if (!data) throw new Error(messageFor(errorCode(error, response)))
      return data
    },
  })
  const isOwner = session.data?.role === 'owner'
  const allAccounts = accounts.data?.accounts ?? []
  const needle = normalize(search)
  const visibleAccounts = allAccounts.filter((account) => (!role || account.role === role) &&
    (!needle || normalize(account.displayName).includes(needle) || normalize(account.username).includes(needle)))
  visibleAccounts.sort((left, right) => {
    const byLogin = sort === 'login' ? (Date.parse(right.lastLoginAt ?? '') || 0) - (Date.parse(left.lastLoginAt ?? '') || 0) : 0
    return byLogin || accountNames.compare(left.displayName, right.displayName) || accountNames.compare(left.username, right.username)
  })

  function confirmDelete(account: Account) {
    modals.openConfirmModal({
      title: 'حذف حساب الويب',
      centered: true,
      children: (
        <Stack gap="xs">
          <Text size="sm" fw={600} dir="ltr" ta="start" className="cgb-mono">{account.username}</Text>
          <Text size="sm">
          {account.webOnly
            ? `سيُحذف حساب «${account.displayName}» ويفقد صلاحيته في الجسر كله، وتُنهى جلساته المفتوحة.`
            : `ستُحذف كلمة مرور «${account.displayName}» للويب. حسابه في البوت يبقى كما هو، ويستطيع الدخول عبر Telegram.`}
          </Text>
        </Stack>
      ),
      labels: { confirm: 'حذف', cancel: 'إلغاء' },
      confirmProps: { color: 'red' },
      onConfirm: async () => {
        setDeleting(true)
        try {
          const { error, response } = await api.DELETE('/api/accounts/{username}', { params: { path: { username: account.username } } })
          if (response.ok) {
            notifications.show({ color: 'green', message: 'حُذف الحساب.' })
            await queryClient.invalidateQueries({ queryKey: accountsKey })
          } else {
            notifications.show({ color: 'red', message: messageFor(errorCode(error, response)) })
          }
        } catch {
          notifications.show({ color: 'red', message: 'تعذّر تأكيد الحذف. حدّث قائمة الحسابات للتحقق قبل المحاولة مرة أخرى.' })
        } finally {
          setDeleting(false)
        }
      },
    })
  }

  return (
    <Stack gap="lg">
      <PageHeader title="الحسابات" description="إدارة حسابات الويب وكلمات المرور والصلاحيات." actions={
        <Group gap="xs">
          {accounts.data && <Button variant="default" leftSection={<IconRefresh size={16} />} loading={accounts.isFetching}
            onClick={() => void accounts.refetch()}>تحديث</Button>}
          <Button leftSection={<IconPlus size={18} />} onClick={create.open} disabled={!accounts.data}>حساب جديد</Button>
        </Group>
      } />

      {accounts.isError && <Alert color="red" role="alert">
        <Group justify="space-between">
          <Text size="sm">{accounts.error.message}</Text>
          <Button variant="subtle" size="compact-sm" loading={accounts.isFetching} onClick={() => void accounts.refetch()}>إعادة المحاولة</Button>
        </Group>
      </Alert>}

      {!!allAccounts.length && <Stack gap="xs">
        <SimpleGrid cols={{ base: 1, sm: 3 }} spacing="sm">
          <TextInput label="بحث في الحسابات" placeholder="الاسم أو اسم المستخدم" type="search" dir="rtl" maxLength={120}
            leftSection={<IconSearch size={16} />} value={search} onChange={(event) => setSearch(event.currentTarget.value)} />
          <NativeSelect label="الدور" value={role} onChange={(event) => setRole(event.currentTarget.value)}
            data={[{ value: '', label: 'جميع الأدوار' }, ...Object.entries(roleLabel).map(([value, label]) => ({ value, label }))]} />
          <NativeSelect label="ترتيب العرض" value={sort} onChange={(event) => setSort(event.currentTarget.value)}
            data={[{ value: 'name', label: 'الاسم' }, { value: 'login', label: 'الأحدث دخولًا' }]} />
        </SimpleGrid>
        {(needle || role) && <Text size="sm" c="dimmed" role="status">
          {number.format(visibleAccounts.length)} من {number.format(allAccounts.length)} حساب
        </Text>}
      </Stack>}

      {(accounts.data || accounts.isPending) && <Paper radius="lg" p={0} style={{ overflow: 'hidden' }}>
        {accounts.isPending ? (
          <Stack p="lg">
            <Skeleton h={20} />
            <Skeleton h={20} />
            <Skeleton h={20} />
          </Stack>
        ) : !allAccounts.length ? (
          <Stack p="xl" align="center" gap={4}>
            <Text fw={600}>لا حسابات بكلمة مرور بعد</Text>
            <Text size="sm" c="dimmed">
              من في البوت يدخل عبر Telegram دون حساب هنا. أضف حسابًا لمن يحتاج كلمة مرور، أو لشخص بلا Telegram.
            </Text>
          </Stack>
        ) : !visibleAccounts.length ? (
          <Stack p="xl" align="center" gap="xs">
            <Text c="dimmed">لا توجد حسابات تطابق البحث والتصفية.</Text>
            <Button variant="subtle" onClick={() => { setSearch(''); setRole('') }}>مسح البحث والتصفية</Button>
          </Stack>
        ) : (
          <Table.ScrollContainer minWidth={720} aria-label="جدول حسابات الويب" tabIndex={0}>
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
                {visibleAccounts.map((account) => {
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
                        <Text size="sm" className="cgb-mono" span dir="ltr">
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
                            <ActionIcon variant="subtle" color="gray" size={36} disabled={deleting} aria-label={`إجراءات ${account.displayName}`}>
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
      </Paper>}

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
