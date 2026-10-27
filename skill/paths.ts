// server.ts と client.ts が使う場所。メニューバーのアプリ（app/Sources/FigmaBridge/Locations.swift）も同じ場所を使う
import { homedir, tmpdir } from 'node:os'
import { join } from 'node:path'

// plugin/manifest.json の devAllowedDomains と plugin/ui.html の BRIDGE_URL に合わせる
export const PORT = 3055
export const BASE_URL = `http://127.0.0.1:${PORT}`

// トークンと PID はリポジトリの外に置く。AI がリポジトリを検索したときに、トークンが出力に混ざらないようにするため
export const STATE_DIR = join(homedir(), 'Library', 'Application Support', 'figma_bridge')
export const TOKEN_PATH = join(STATE_DIR, '.token')
// client.ts の start が起動したサーバーの PID。アプリやターミナルで起動したサーバーの PID は書かない
export const PID_PATH = join(STATE_DIR, '.pid')
// プラグインが接続するときに送る合言葉。scripts/install.sh が作り、plugin/ui.local.html に埋め込む
export const PLUGIN_KEY_PATH = join(STATE_DIR, '.plugin-key')
export const LOG_PATH = join(homedir(), 'Library', 'Logs', 'figma_bridge', 'server.log')
export const EXPORT_DIR = join(tmpdir(), 'figma_bridge')
