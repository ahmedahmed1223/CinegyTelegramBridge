import { Button } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useMutation } from '@tanstack/react-query'
import { IconDownload } from '@tabler/icons-react'
import { api, errorCode } from '../../api/client'
import { messageFor } from '../../api/messages'

export function SettingsExportButton() {
  const exportSettings = useMutation({
    mutationFn: async () => {
      const { data, error, response } = await api.GET('/api/admin/settings/export')
      if (!data) throw new Error(errorCode(error, response))
      const url = URL.createObjectURL(new Blob([JSON.stringify(data, null, 2)], { type: 'application/json;charset=utf-8' }))
      const link = document.createElement('a')
      link.href = url
      link.download = 'cinegy-web-settings.json'
      document.body.appendChild(link)
      link.click()
      link.remove()
      setTimeout(() => URL.revokeObjectURL(url), 1000)
    },
    onError: (error) => notifications.show({
      title: 'تعذّر تصدير إعدادات الويب',
      message: error.message === 'setting_export_unavailable' ? 'لا توجد قيم صالحة للتصدير.' : messageFor(error.message),
      color: 'red',
    }),
  })
  return (
    <Button variant="default" leftSection={<IconDownload size={16} />} loading={exportSettings.isPending}
      onClick={() => exportSettings.mutate()}>تنزيل إعدادات الويب</Button>
  )
}
