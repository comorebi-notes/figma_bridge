/* global figma, __html__ */
// server.ts から届いた命令を、Figma アプリで開いているファイルに対して実行する。
// クラウドで動く Figma MCP（use_figma）が読み込めないローカルのフォント（Font Awesome 7 Pro など）も、アプリの中なら読み込める

figma.showUI(__html__, { width: 240, height: 64, title: 'Claude Figma Bridge', themeColors: true })

const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor

// v7-icon のレイヤー名に付ける印。例: fass fa-megaphone（icon-name: megaphone）
const DEFAULT_ICON_MARKER = '[（(]icon-name:\\s*([a-z0-9-]+)[）)]'
// v7-icon には icon-name#…、icon-name##…、icon-name###… の 3 つがあり、表示に使うのは # が 1 つのもの
const DEFAULT_ICON_PROPERTY = '^icon-name#[^#]'

const reportProgress = (text) => figma.ui.postMessage({ type: 'progress', text: String(text) })

const isNode = (value) => typeof value.id === 'string' && typeof value.type === 'string' && 'parent' in value

// run の戻り値を JSON にできる形に直す。ノードは ID と種類と名前だけにする
const toPlain = (value, depth = 0) => {
  if (value === undefined || value === null) return null
  if (typeof value === 'symbol') return value === figma.mixed ? '[mixed]' : String(value)
  if (typeof value === 'function') return undefined
  if (typeof value !== 'object') return value
  if (value instanceof Uint8Array) return { bytes: value.length }
  try {
    if (isNode(value)) return { id: value.id, type: value.type, name: value.name }
  } catch (error) {
    return { error: `ノードを読めません: ${error.message}` }
  }
  if (depth > 20) return '[depth limit]'
  if (Array.isArray(value)) return value.map((item) => toPlain(item, depth + 1))
  const plain = {}
  for (const [key, item] of Object.entries(value)) plain[key] = toPlain(item, depth + 1)
  return plain
}

const isInsideInstance = (node) => {
  for (let parent = node.parent; parent; parent = parent.parent) {
    if (parent.type === 'INSTANCE') return true
  }
  return false
}

const pageOf = (node) => {
  let current = node
  while (current && current.type !== 'PAGE') current = current.parent
  return current
}

const resolveRoots = async (nodeIds) => {
  if (!nodeIds || nodeIds.length === 0) return [figma.currentPage]

  const roots = []
  for (const id of nodeIds) {
    const node = await figma.getNodeByIdAsync(id)
    if (!node) throw new Error(`ノードが見つかりません: ${id}`)
    const page = pageOf(node)
    if (page) await page.loadAsync()
    roots.push(node)
  }
  return roots
}

const collect = (roots, predicate) => roots.flatMap((root) => [
  ...(predicate(root) ? [root] : []),
  ...('findAll' in root ? root.findAll(predicate) : [])
])

// loadFontAsync は呼ぶたびに数秒かかり、途中で戻らなくなったこともあったため、同じフォントは 1 回だけ読み込む
const loadedFonts = new Set()
const loadFont = async (fontName) => {
  const key = `${fontName.family}/${fontName.style}`
  if (loadedFonts.has(key)) return
  await figma.loadFontAsync(fontName)
  loadedFonts.add(key)
}

const loadFontsOf = async (textNodes) => {
  for (const text of textNodes) {
    for (const segment of text.getStyledTextSegments(['fontName'])) await loadFont(segment.fontName)
  }
}

const fillIconNames = async ({ nodeIds, marker = DEFAULT_ICON_MARKER, property = DEFAULT_ICON_PROPERTY, keepMarker = false, dryRun = false }) => {
  const markerPattern = new RegExp(marker)
  const propertyPattern = new RegExp(property)
  const icons = collect(await resolveRoots(nodeIds), (node) => node.type === 'INSTANCE' && markerPattern.test(node.name))
  const results = []

  for (const [index, icon] of icons.entries()) {
    reportProgress(`アイコン ${index + 1} / ${icons.length}`)
    const iconName = icon.name.match(markerPattern)[1]
    const result = { id: icon.id, name: icon.name, iconName }
    try {
      const key = Object.keys(icon.componentProperties).find((name) => propertyPattern.test(name))
      if (!key) throw new Error(`${property} に合うプロパティがありません`)
      if (!dryRun) {
        const texts = icon.findAll((node) => node.type === 'TEXT')
        const bound = texts.filter((node) => node.componentPropertyReferences && node.componentPropertyReferences.characters === key)
        await loadFontsOf(bound.length > 0 ? bound : texts.filter((node) => node.visible))
        icon.setProperties({ [key]: iconName })
        if (!keepMarker) icon.name = icon.name.replace(markerPattern, '').trim()
      }
    } catch (error) {
      result.error = error.message
    }
    results.push(result)
  }
  return { dryRun, icons: results }
}

// テキストスタイルがある文字と、インスタンスの中の文字は、既定では部品側の指定を優先して変えない
const replaceFonts = async ({ nodeIds, from, to, styles = {}, includeStyled = false, includeInstances = false, dryRun = false }) => {
  if (!from || !to) throw new Error('from と to にフォントファミリーの名前を渡してください')

  const availableStyles = new Set(
    (await figma.listAvailableFontsAsync())
      .filter(({ fontName }) => fontName.family === to)
      .map(({ fontName }) => fontName.style)
  )
  if (availableStyles.size === 0) throw new Error(`このアプリでは ${to} を使えません`)

  const texts = collect(await resolveRoots(nodeIds), (node) => node.type === 'TEXT' && (includeInstances || !isInsideInstance(node)))
  const changed = []
  const missingStyles = new Set()

  for (const [index, text] of texts.entries()) {
    reportProgress(`文字 ${index + 1} / ${texts.length}`)
    const segments = text.getStyledTextSegments(['fontName', 'textStyleId'])
      .filter(({ fontName, textStyleId }) => fontName.family === from && (includeStyled || !textStyleId))
    if (segments.length === 0) continue

    const result = { id: text.id, text: text.characters.slice(0, 20), styles: [...new Set(segments.map(({ fontName }) => fontName.style))] }
    try {
      if (!dryRun) await loadFontsOf([text])
      for (const { start, end, fontName } of segments) {
        const style = styles[fontName.style] || fontName.style
        if (!availableStyles.has(style)) {
          missingStyles.add(style)
          continue
        }
        if (dryRun) continue
        const target = { family: to, style }
        await loadFont(target)
        text.setRangeFontName(start, end, target)
      }
    } catch (error) {
      result.error = error.message
    }
    changed.push(result)
  }
  return { dryRun, changed, missingStyles: [...missingStyles] }
}

const commands = {
  status: async () => ({
    fileName: figma.root.name,
    fileKey: figma.fileKey,
    editorType: figma.editorType,
    page: { id: figma.currentPage.id, name: figma.currentPage.name },
    selection: figma.currentPage.selection.map(({ id, name, type }) => ({ id, name, type }))
  }),

  fonts: async ({ match }) => {
    const pattern = match ? new RegExp(match, 'i') : null
    const families = {}
    for (const { fontName } of await figma.listAvailableFontsAsync()) {
      if (pattern && !pattern.test(fontName.family)) continue
      if (!families[fontName.family]) families[fontName.family] = []
      families[fontName.family].push(fontName.style)
    }
    return families
  },

  // use_figma と同じく、figma を使う JavaScript を async 関数の本体として実行し、return した値を返す
  run: async ({ code, args = {} }) => {
    if (typeof code !== 'string' || code.trim() === '') throw new Error('code に実行する JavaScript を渡してください')
    const logs = []
    const log = (...items) => logs.push(items.map((item) => (typeof item === 'string' ? item : JSON.stringify(toPlain(item)))).join(' '))
    const value = await new AsyncFunction('figma', 'args', 'log', 'progress', code)(figma, args, log, reportProgress)
    return { value: toPlain(value), logs }
  },

  'fill-icon-names': fillIconNames,

  'replace-fonts': replaceFonts,

  export: async ({ nodeId, format = 'PNG', scale = 2 }) => {
    const node = await figma.getNodeByIdAsync(nodeId)
    if (!node || !('exportAsync' in node)) throw new Error(`書き出せるノードではありません: ${nodeId}`)
    const settings = format === 'SVG' || format === 'PDF' ? { format } : { format, constraint: { type: 'SCALE', value: scale } }
    const bytes = await node.exportAsync(settings)
    return { nodeId, name: node.name, format, width: node.width, height: node.height, base64: figma.base64Encode(bytes) }
  }
}

const READ_ONLY_COMMANDS = new Set(['status', 'fonts', 'export'])

// サーバーが時間切れで応答を待たなくなっても、プラグインの処理は続く。そこへ次の命令が来て同じノードを並行して変えないようにする
let runningCommand = null

figma.ui.onmessage = async (message) => {
  // UI はブリッジにつながるたびにこれを送る。開いているファイルの名前を返し、UI からサーバーへ知らせる
  if (message && message.type === 'hello') {
    figma.ui.postMessage({ type: 'hello', fileName: figma.root.name })
    return
  }
  if (!message || message.type !== 'command') return

  const { id, command, params = {} } = message
  const changesDocument = !READ_ONLY_COMMANDS.has(command)
  try {
    if (changesDocument && runningCommand) throw new Error(`前の命令（${runningCommand}）を実行中です`)
    // 別のファイルでプラグインを開いたまま命令を送ってしまったときに、そのファイルを書き換えないようにする
    if (params.expectedFileName && params.expectedFileName !== figma.root.name) {
      throw new Error(`開いているファイルが違います（開いているファイル: ${figma.root.name}）`)
    }
    if (params.expectedFileKey && figma.fileKey && params.expectedFileKey !== figma.fileKey) {
      throw new Error(`開いているファイルが違います（開いているファイルのキー: ${figma.fileKey}）`)
    }
    const run = commands[command]
    if (!run) throw new Error(`未対応の命令です: ${command}`)
    if (changesDocument) runningCommand = command
    figma.ui.postMessage({ id, command, ok: true, result: await run(params) })
  } catch (error) {
    figma.ui.postMessage({ id, command, ok: false, error: error && error.message ? error.message : String(error) })
  } finally {
    if (changesDocument && runningCommand === command) runningCommand = null
  }
}
