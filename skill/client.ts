// server.ts の起動と停止、命令の送信を行う CLI。結果は JSON で標準出力に出す。使い方は SKILL.md
//   bun client.ts start | stop
//   bun client.ts status
//   bun client.ts run script.js [--args '{"nodeId":"1:2"}']
//   bun client.ts export 1:2 [--format PNG] [--scale 2] [--out path/to.png]
//   bun client.ts <命令> ['<JSON の params>']
// どの命令にも --file-name、--file-key（開いているファイルの確認）と --timeout（ミリ秒）を付けられる
// stop が止めるのは start で起動したサーバーだけで、メニューバーのアプリやターミナルで動いているサーバーは止めない
import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, openSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { BASE_URL, LOG_PATH, PID_PATH, STATE_DIR, TOKEN_PATH } from './paths.ts'

const SERVER_PATH = fileURLToPath(new URL('./server.ts', import.meta.url))

const fail = (message: string): never => {
  console.error(message)
  process.exit(1)
}

// 認証の前に応答があるかだけを見る。401 が返っても、待ち受けているなら起動中とみなす
const isListening = async () => {
  try {
    await fetch(`${BASE_URL}/status`)
    return true
  } catch {
    return false
  }
}

const isRunning = (pid: number) => {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

// .pid のプロセスが server.ts を動かしていれば、その PID を返す。PID はほかのプロセスに使い回されることがあるため、コマンドまで確かめる。古い .pid は消す
const startedPid = () => {
  if (!existsSync(PID_PATH)) return null
  const pid = Number(readFileSync(PID_PATH, 'utf8'))
  const command = Bun.spawnSync(['/bin/ps', '-o', 'command=', '-p', String(pid)]).stdout.toString()
  if (command.includes('server.ts')) return pid
  rmSync(PID_PATH, { force: true })
  return null
}

const startServer = async () => {
  if (await isListening()) {
    return console.log(startedPid()
      ? 'サーバーはすでに起動しています（start で起動したサーバーです）'
      : 'サーバーはすでに起動しています（メニューバーのアプリかターミナルで起動したサーバーで、stop では止めません）')
  }

  mkdirSync(dirname(LOG_PATH), { recursive: true })
  mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 })
  const log = openSync(LOG_PATH, 'a')
  // ターミナルや Claude のセッションを閉じても止まらないよう、親から切り離して起動する
  const child = spawn(process.execPath, [SERVER_PATH], { detached: true, stdio: ['ignore', log, log] })
  child.unref()
  writeFileSync(PID_PATH, String(child.pid))
  for (let i = 0; i < 30; i += 1) {
    if (await isListening()) return console.log(`サーバーを起動しました（PID ${child.pid}、ログ ${LOG_PATH}）`)
    await Bun.sleep(100)
  }
  fail(`サーバーが起動しませんでした。ログを確かめてください: ${LOG_PATH}`)
}

const stopServer = async () => {
  const pid = startedPid()
  if (pid === null) {
    return console.log(await isListening()
      ? 'start で起動したサーバーではないため止めません。サーバーはメニューバーのアプリかターミナルで動いています'
      : 'サーバーは起動していません')
  }
  process.kill(pid, 'SIGTERM')
  for (let i = 0; i < 30 && isRunning(pid); i += 1) await Bun.sleep(100)
  rmSync(PID_PATH, { force: true })
  console.log(`サーバーを止めました（PID ${pid}）`)
}

if (process.argv[2] === 'start') {
  await startServer()
  process.exit(0)
}
if (process.argv[2] === 'stop') {
  await stopServer()
  process.exit(0)
}

const argv = process.argv.slice(2)
const option = (name: string) => {
  const index = argv.indexOf(`--${name}`)
  if (index === -1) return undefined
  const [, value] = argv.splice(index, 2)
  return value
}
const parseJson = (text: string | undefined, label: string) => {
  if (text === undefined) return {}
  try {
    return JSON.parse(text)
  } catch {
    return fail(`${label} を JSON として読めません: ${text}`)
  }
}

const timeoutMs = option('timeout')
const fileName = option('file-name')
const fileKey = option('file-key')
const args = parseJson(option('args'), '--args')
const format = option('format')
const scale = option('scale')
const outPath = option('out')
const [command, target] = argv

if (!command) fail('命令を指定してください。例: bun client.ts status')
if (!existsSync(TOKEN_PATH)) fail('サーバーが起動していません。先に bun ~/.claude/skills/figma_bridge/client.ts start を実行してください')
const headers = { Authorization: `Bearer ${readFileSync(TOKEN_PATH, 'utf8').trim()}`, 'Content-Type': 'application/json' }

const request = async (path: string, init: RequestInit = {}) => {
  try {
    const response = await fetch(`${BASE_URL}${path}`, { ...init, headers })
    return await response.json()
  } catch (error) {
    return fail(`サーバーに接続できません（${(error as Error).message}）。server.ts が起動しているか確かめてください`)
  }
}

const buildParams = (): Record<string, unknown> => {
  if (command === 'run') {
    if (!target) fail('実行する JavaScript のファイルを指定してください（標準入力から読むときは -）')
    const code = target === '-' ? readFileSync(0, 'utf8') : readFileSync(target, 'utf8')
    return { code, args }
  }
  if (command === 'export') {
    if (!target) fail('書き出すノードの ID を指定してください')
    return { nodeId: target, ...(format && { format }), ...(scale && { scale: Number(scale) }), ...(outPath && { outPath }) }
  }
  return parseJson(target, 'params')
}

const connection = await request('/status')
if (!connection.ok) fail(JSON.stringify(connection))
if (!connection.connected) fail('プラグインが接続されていません。Figma アプリで Claude Figma Bridge を起動してください')

const params = { ...buildParams(), ...(fileName && { expectedFileName: fileName }), ...(fileKey && { expectedFileKey: fileKey }) }
const reply = await request('/command', {
  method: 'POST',
  body: JSON.stringify({ command, params, ...(timeoutMs && { timeoutMs: Number(timeoutMs) }) })
})
console.log(JSON.stringify(reply, null, 2))
if (!reply.ok) process.exit(1)
