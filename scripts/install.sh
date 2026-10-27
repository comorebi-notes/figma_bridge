#!/bin/bash
# スキルとプラグインを ~/.claude/skills/figma_bridge に入れ、メニューバーのアプリをビルドして ~/Applications/FigmaBridge.app に置く。何度実行してもよい
#   ./scripts/install.sh          skill/ をコピーする。済んだら、このフォルダがなくても動く
#   ./scripts/install.sh --link   skill/ へのリンクを作る。skill/ を直すとすぐに反映されるため、開発するときに使う
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
skill_dir="$HOME/.claude/skills/figma_bridge"
bundle="$repo/app/.build/FigmaBridge.app"
app="$HOME/Applications/FigmaBridge.app"

case "${1:-}" in
  "") mode=copy ;;
  --link) mode=link ;;
  *) echo "使い方: $0 [--link]" >&2; exit 1 ;;
esac

# 前にこのスクリプトで入れたものだけを置き換える
if [ -e "$skill_dir" ] && [ ! -L "$skill_dir" ] && ! grep -qx 'name: figma_bridge' "$skill_dir/SKILL.md" 2>/dev/null; then
  echo "$skill_dir に figma_bridge 以外のものがあるため、作業を止めました。中身を確かめてから移すか消し、もう一度実行してください" >&2
  exit 1
fi
mkdir -p "$(dirname "$skill_dir")"
# リンクの末尾に / を付けないので、消えるのはリンクだけで、リンク先の skill/ は消えない
rm -rf "$skill_dir"
if [ "$mode" = link ]; then
  ln -s "$repo/skill" "$skill_dir"
  echo "スキル: $skill_dir -> $repo/skill（リンク）"
else
  ditto "$repo/skill" "$skill_dir"
  echo "スキル: $skill_dir（コピー）"
fi

# プラグインが接続するときに送る合言葉を作り、plugin/ui.html から合言葉入りの ui.local.html を作る。サーバーは、合言葉を知らない接続を断る
# 場所は skill/paths.ts の PLUGIN_KEY_PATH に合わせる。2 回目からは同じ合言葉を使う
state_dir="$HOME/Library/Application Support/figma_bridge"
key_file="$state_dir/.plugin-key"
mkdir -p -m 700 "$state_dir"
if [ ! -s "$key_file" ]; then
  (umask 077 && openssl rand -hex 24 > "$key_file")
fi
(umask 077 && sed "s/__PLUGIN_KEY__/$(cat "$key_file")/" "$skill_dir/plugin/ui.html" > "$skill_dir/plugin/ui.local.html")

swift build --package-path "$repo/app" -c release
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS"
cp "$repo/app/.build/release/FigmaBridge" "$bundle/Contents/MacOS/"
cp "$repo/app/Info.plist" "$bundle/Contents/"
# 自分の Mac で使うだけなので、Apple Developer の証明書を使わない ad-hoc 署名にする
codesign --force --sign - "$bundle"

# 動いているアプリを終了してから入れ替える。アプリが起動したサーバーも止まる
if pkill -x FigmaBridge; then
  sleep 1
fi
mkdir -p "$(dirname "$app")"
rm -rf "$app"
ditto "$bundle" "$app"
open "$app"
echo "アプリ: $app"
echo "Figma で読み込むプラグインのファイル: $skill_dir/plugin/manifest.json"
echo "初めて使うときや、前に別の場所から読み込んでいたときは、Figma でこのファイルを読み込んでください。メニューバーのアプリの「Figma プラグインのファイルを表示」で、Finder に表示してパスをコピーできます"
