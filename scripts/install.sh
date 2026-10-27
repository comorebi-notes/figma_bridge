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
