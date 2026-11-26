import { ActionIcon, Group, Table, Tooltip, type TableProps, type TableTrProps } from '@mantine/core'
import { IconGripVertical, IconRestore } from '@tabler/icons-react'
import { Children, createContext, useContext, useRef, useState, type PointerEvent, type ReactNode } from 'react'
import classes from './AdjustableTable.module.css'

export type AdjustableColumn = {
  id: string
  label: string
  width: number
  minWidth?: number
  header?: ReactNode
}

type Layout = { order: string[]; widths: Record<string, number> }
type Gesture = { id: string; kind: 'resize' | 'move'; start: number; width: number; rtl: boolean }
const ColumnPositions = createContext<number[]>([])
const emptyLayout: Layout = { order: [], widths: {} }

function readLayout(key: string): Layout {
  try {
    const saved = JSON.parse(localStorage.getItem(key) ?? 'null') as Partial<Layout> | null
    return {
      order: Array.isArray(saved?.order) ? saved.order.filter((id) => typeof id === 'string') : [],
      widths: saved?.widths && typeof saved.widths === 'object' ? saved.widths : {},
    }
  } catch { return emptyLayout }
}

export function AdjustableRow({ children, ...props }: TableTrProps) {
  const positions = useContext(ColumnPositions)
  const cells = Children.toArray(children)
  return <Table.Tr {...props}>{cells.length === positions.length ? positions.map((index) => cells[index]) : cells}</Table.Tr>
}

export function AdjustableTable({ layoutKey, columns, label, children, ...props }: Omit<TableProps, 'children'> & {
  layoutKey: string
  columns: AdjustableColumn[]
  label: string
  children: ReactNode
}) {
  const storageKey = 'cgb-table-layout:' + layoutKey
  const [layout, setLayout] = useState(() => readLayout(storageKey))
  const [preview, setPreview] = useState<{ id: string; width: number }>()
  const [moving, setMoving] = useState<string>()
  const [over, setOver] = useState<string>()
  const gesture = useRef<Gesture | null>(null)
  const tableRef = useRef<HTMLTableElement>(null)
  const ids = columns.map((column) => column.id)
  const order = [...new Set([...layout.order.filter((id) => ids.includes(id)), ...ids])]
  const positions = order.map((id) => ids.indexOf(id))
  const ordered = positions.map((index) => columns[index])
  const bound = (column: AdjustableColumn, value: number) => Math.max(column.minWidth ?? 80, Math.min(value, 1200))
  const widthOf = (column: AdjustableColumn) => bound(column, preview?.id === column.id ? preview.width :
    Number.isFinite(layout.widths[column.id]) ? layout.widths[column.id] : column.width)
  const tableWidth = ordered.reduce((sum, column) => sum + widthOf(column), 0)

  function save(next: Layout) {
    setLayout(next)
    try { localStorage.setItem(storageKey, JSON.stringify(next)) } catch { /* still works for this visit */ }
  }

  function move(id: string, target: string) {
    const destination = order.indexOf(target)
    if (destination < 0 || target === id) return
    const next = order.filter((column) => column !== id)
    next.splice(destination, 0, id)
    const hidden = layout.order.filter((column) => !ids.includes(column))
    save({ ...layout, order: [...next, ...hidden] })
  }

  function columnAt(event: PointerEvent) {
    const hit = document.elementFromPoint(event.clientX, event.clientY)?.closest<HTMLElement>('[data-layout-column]')
    return hit && tableRef.current?.contains(hit) ? hit.dataset.layoutColumn : undefined
  }

  function start(event: PointerEvent<HTMLButtonElement>, column: AdjustableColumn, kind: Gesture['kind']) {
    if (!event.isPrimary || event.button !== 0) return
    gesture.current = { id: column.id, kind, start: event.clientX, width: widthOf(column), rtl: getComputedStyle(event.currentTarget).direction === 'rtl' }
    event.currentTarget.setPointerCapture(event.pointerId)
    if (kind === 'move') setMoving(column.id)
  }

  function change(event: PointerEvent<HTMLButtonElement>, column: AdjustableColumn, finish = false) {
    const active = gesture.current
    if (!active || active.id !== column.id) return
    if (active.kind === 'resize') {
      const width = bound(column, Math.round(active.width + (event.clientX - active.start) * (active.rtl ? -1 : 1)))
      if (finish && width !== active.width) save({ ...layout, widths: { ...layout.widths, [column.id]: width } })
      if (!finish) setPreview({ id: column.id, width })
    } else {
      const target = columnAt(event)
      if (finish && target) move(column.id, target)
      else setOver(target)
    }
    if (finish) cancel()
  }

  function cancel() {
    gesture.current = null
    setPreview(undefined)
    setMoving(undefined)
    setOver(undefined)
  }

  return <>
    {(layout.order.length > 0 || Object.keys(layout.widths).length > 0) && <Group justify="flex-end">
      <Tooltip label="إعادة ترتيب الأعمدة وعروضها إلى الوضع الافتراضي">
        <ActionIcon type="button" variant="subtle" color="gray" aria-label="إعادة ضبط الأعمدة" onClick={() => save(emptyLayout)}>
          <IconRestore size={17} aria-hidden />
        </ActionIcon>
      </Tooltip>
    </Group>}
    <Table.ScrollContainer minWidth={tableWidth} type="native" tabIndex={0} aria-label={label}>
      <Table {...props} ref={tableRef} aria-label={label} layout="fixed" w={tableWidth} className={classes.table}>
        <colgroup>{ordered.map((column) => <col key={column.id} style={{ width: widthOf(column) }} />)}</colgroup>
        <Table.Thead><Table.Tr>{ordered.map((column, index) => (
          <Table.Th key={column.id} scope="col" data-layout-column={column.id}
            data-column-target={moving && moving !== column.id && over === column.id || undefined} className={classes.header}>
            <div className={classes.label}>
              <button type="button" className={classes.handle} aria-label={`ترتيب عمود ${column.label}`}
                title="اسحب لترتيب العمود أو استخدم السهمين"
                onPointerDown={(event) => start(event, column, 'move')}
                onPointerMove={(event) => change(event, column)}
                onPointerUp={(event) => change(event, column, true)} onPointerCancel={cancel} onLostPointerCapture={cancel}
                onKeyDown={(event) => {
                  if (event.key !== 'ArrowRight' && event.key !== 'ArrowLeft') return
                  event.preventDefault()
                  const direction = (event.key === 'ArrowRight' ? 1 : -1) * (getComputedStyle(event.currentTarget).direction === 'rtl' ? -1 : 1)
                  const target = order[index + direction]
                  if (target) move(column.id, target)
                }}>
                <IconGripVertical size={16} aria-hidden />
              </button>
              <span>{column.header ?? column.label}</span>
            </div>
            <button type="button" className={classes.resize} aria-label={`تغيير عرض عمود ${column.label}`}
              title="اسحب لتغيير العرض أو استخدم السهمين"
              onPointerDown={(event) => start(event, column, 'resize')}
              onPointerMove={(event) => change(event, column)}
              onPointerUp={(event) => change(event, column, true)} onPointerCancel={cancel} onLostPointerCapture={cancel}
              onKeyDown={(event) => {
                if (event.key !== 'ArrowRight' && event.key !== 'ArrowLeft') return
                event.preventDefault()
                const direction = (event.key === 'ArrowRight' ? 1 : -1) * (getComputedStyle(event.currentTarget).direction === 'rtl' ? -1 : 1)
                save({ ...layout, widths: { ...layout.widths, [column.id]: bound(column, widthOf(column) + direction * 16) } })
              }} />
          </Table.Th>
        ))}</Table.Tr></Table.Thead>
        <ColumnPositions.Provider value={positions}>{children}</ColumnPositions.Provider>
      </Table>
    </Table.ScrollContainer>
  </>
}
