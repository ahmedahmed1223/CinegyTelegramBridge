import { Button } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useMutation } from '@tanstack/react-query'
import { IconDownload } from '@tabler/icons-react'
import { api, errorCode } from '../../api/client'
import { messageFor } from '../../api/messages'

export function RuntimeDiagnosticBundleButton() {
  const download = useMutation({
    mutationFn: async () => {
      const { data, error, response } = await api.GET('/api/admin/diagnostics/runtime-bundle', { parseAs: 'blob' })
      if (!data) throw new Error(errorCode(error, response))
      const url = URL.createObjectURL(data)
      const link = document.createElement('a')
      link.href = url
      link.download = 'cinegy-bridge-diagnostics.zip'
      document.body.appendChild(link)
      link.click()
      link.remove()
      setTimeout(() => URL.revokeObjectURL(url), 1000)
    },
    onError: (error) => notifications.show({
      title: 'تعذّر تنزيل حزمة التشخيص',
      message: messageFor(error.message),
      color: 'red',
    }),
  })

  return (
    <Button variant="default" leftSection={<IconDownload size={16} />} loading={download.isPending}
      onClick={() => download.mutate()}>تنزيل حزمة التشخيص</Button>
  )
}
