// AI（Claude Code など）と、Figma アプリで動く Claude Figma Bridge プラグインの間で命令を中継する。使い方は SKILL.md
//   bun server.ts [--exit-on-stdin-close]
// --exit-on-stdin-close を付けると、標準入力が閉じたときに止まる。メニューバーのアプリが強制終了したときに、サーバーを残さないために使う
import type { ServerWebSocket } from 'bun'
import { randomBytes } from 'node:crypto'
import { mkdirSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { EXPORT_DIR, PID_PATH, PORT, STATE_DIR, TOKEN_PATH } from './paths.ts'

const DEFAULT_TIMEOUT_MS = 120_000
// GET /history で返す件数。記録はメモリにだけ持ち、サーバーを止めると消える
const HISTORY_LIMIT = 20

type PluginReply = { id: string, command?: string, ok: boolean, result?: any, error?: string }
// メニューバーのアプリに見せる命令の記録。命令の引数と結果は含めない
type HistoryEntry = { at: number, command: string, ok: boolean, ms: number, error?: string }

const token = randomBytes(24).toString('hex')

let plugin: ServerWebSocket<unknown> | null = null
// 接続中のプラグインが開いているファイルの名前。プラグインが接続したときに知らせてくる
let fileName: string | null = null
const pending = new Map<string, (reply: PluginReply) => void>()
const history: HistoryEntry[] = []

// sv-SE の書式で「2026-10-27 10:32:05」の形の時刻を付ける
const log = (message: string) => console.log(`${new Date().toLocaleString('sv-SE')} ${message}`)

// export の画像は JSON に入れると大きいため、ファイルに書き出してパスを返す
const saveExport = (reply: PluginReply, params: Record<string, any>) => {
  const { base64, format = 'PNG', nodeId = 'node' } = reply.result ?? {}
  if (!reply.ok || typeof base64 !== 'string') return reply

  const path = params.outPath
    ? resolve(params.outPath)
    : join(EXPORT_DIR, `${String(nodeId).replace(/[^0-9A-Za-z-]/g, '-')}-${Date.now()}.${String(format).toLowerCase()}`)
  mkdirSync(dirname(path), { recursive: true })
  const bytes = Buffer.from(base64, 'base64')
  writeFileSync(path, bytes)
  const { base64: _omitted, ...rest } = reply.result
  return { ...reply, result: { ...rest, path, bytes: bytes.length } }
}

const record = (command: string, startedAt: number, reply: { ok: boolean, error?: string }) => {
  const ms = Date.now() - startedAt
  const seconds = `${(ms / 1000).toFixed(1)} 秒`
  if (reply.ok) {
    history.unshift({ at: startedAt, command, ok: true, ms })
    log(`命令 ${command} を実行しました（${seconds}）`)
  } else {
    const error = String(reply.error).split('\n')[0].slice(0, 200)
    history.unshift({ at: startedAt, command, ok: false, ms, error })
    log(`命令 ${command} が失敗しました（${seconds}）: ${error}`)
  }
  history.splice(HISTORY_LIMIT)
}

const relay = async (command: string, params: Record<string, any>, timeoutMs: number) => {
  const startedAt = Date.now()
  if (!plugin) {
    const body = { ok: false, error: 'プラグインが接続されていません。Figma アプリで Claude Figma Bridge を起動してください' }
    record(command, startedAt, body)
    return Response.json(body, { status: 503 })
  }

  const id = crypto.randomUUID()
  const reply = await new Promise<PluginReply>((resolveReply) => {
    pending.set(id, resolveReply)
    setTimeout(() => {
      if (pending.delete(id)) resolveReply({ id, ok: false, error: `${timeoutMs / 1000} 秒以内にプラグインから応答がありませんでした。プラグインの処理は続いている場合があります` })
    }, timeoutMs)
    plugin!.send(JSON.stringify({ type: 'command', id, command, params }))
  })
  const body = command === 'export' ? saveExport(reply, params) : reply
  record(command, startedAt, body)
  return Response.json(body, { status: body.ok ? 200 : 500 })
}

Bun.serve({
  hostname: '127.0.0.1',
  port: PORT,
  async fetch(req, server) {
    const { pathname } = new URL(req.url)

    if (pathname === '/plugin') {
      // プラグインの UI は sandbox の iframe で動くため Origin が "null" になる。ブラウザで開いたページからの接続は断る
      const origin = req.headers.get('origin')
      if (origin !== 'null') {
        log(`プラグイン以外からの接続を断りました（Origin: ${origin}）`)
        return new Response('forbidden', { status: 403 })
      }
      return server.upgrade(req) ? undefined : new Response('upgrade failed', { status: 400 })
    }

    if (req.headers.get('authorization') !== `Bearer ${token}`) {
      return Response.json({ ok: false, error: 'unauthorized' }, { status: 401 })
    }
    if (req.method === 'GET' && pathname === '/status') {
      return Response.json({ ok: true, connected: plugin !== null, fileName })
    }
    if (req.method === 'GET' && pathname === '/history') {
      return Response.json({ ok: true, history })
    }
    if (req.method === 'POST' && pathname === '/command') {
      const { command, params = {}, timeoutMs = DEFAULT_TIMEOUT_MS } = await req.json()
      return relay(String(command), params, timeoutMs)
    }
    return Response.json({ ok: false, error: 'not found' }, { status: 404 })
  },
  websocket: {
    open(ws) {
      plugin?.close()
      plugin = ws
      fileName = null
      log('プラグインが接続しました')
    },
    message(ws, data) {
      const message = JSON.parse(String(data))
      // プラグインは接続するたびに、開いているファイルの名前を知らせてくる
      if (message.type === 'hello') {
        if (plugin !== ws) return
        fileName = typeof message.fileName === 'string' ? message.fileName : null
        log(`プラグインが開いているファイル: ${fileName}`)
        return
      }
      const reply: PluginReply = message
      pending.get(reply.id)?.(reply)
      pending.delete(reply.id)
    },
    close(ws) {
      if (plugin !== ws) return
      plugin = null
      fileName = null
      log('プラグインとの接続が切れました')
    },
  },
})

// ポートを確保できてからトークンを書く。別のサーバーがすでに動いていると Bun.serve で止まるため、そのサーバーのトークンを上書きしない
mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 })
writeFileSync(TOKEN_PATH, token, { mode: 0o600 })

const shutdown = (reason: string) => {
  log(`${reason}ため止まります`)
  try { unlinkSync(TOKEN_PATH) } catch { /* 削除済み */ }
  // client.ts の start が書いた .pid が自分のものなら消す。アプリやターミナルから止めたときに、古い .pid を残さないため
  try {
    if (Number(readFileSync(PID_PATH, 'utf8')) === process.pid) unlinkSync(PID_PATH)
  } catch { /* .pid がない */ }
  process.exit(0)
}
process.on('SIGINT', () => shutdown('SIGINT を受けた'))
process.on('SIGTERM', () => shutdown('SIGTERM を受けた'))

if (process.argv.includes('--exit-on-stdin-close')) {
  (async () => {
    for await (const _chunk of Bun.stdin.stream()) { /* 読み捨てる */ }
    shutdown('標準入力が閉じた')
  })()
}

log(`http://127.0.0.1:${PORT} で待機しています（PID ${process.pid}）。命令の送信に使うトークンは ${TOKEN_PATH} にあります`)
