#!/usr/bin/env bash
# gsd-lite: ループが BLOCKED（人の対応待ち）で止まったときに呼ばれるフックのサンプル。
# 使い方: .gsd-lite/hooks/on-blocked.sh にコピーして chmod +x し、下の送信先を 1 つ選ぶ。
#   宛先（Webhook URL 等）をリポジトリに置きたくなければ、このファイルをリポジトリの外
#   （例 ~/.config/gsd-lite/on-blocked.sh）に置き、環境変数 GSD_LITE_ON_BLOCKED にそのパスを入れて起動する。
#
# 引数: $1 = BLOCKED.md のパス（ループ開始後の前提エラーで止まったときは空）
#       $2 = 理由の 1 行（BLOCKED.md の見出しと空行を除いた最初の行、または前提エラーのメッセージ）
#       $3 = ループの終了コード（2 = BLOCKED / 6 = 前提エラー）
# カレントディレクトリはループを起動したディレクトリ。失敗してもループの終了は変わらない。
set -u

file=${1:-}
reason=${2:-}
code=${3:-}
project=$(basename "$PWD")
title="gsd-lite: $project が止まった（exit $code）"
body="$reason${file:+
詳細: $PWD/$file}"

# --- ntfy（https://ntfy.sh。トピック名は推測されにくいものにする）---
# curl -fsS -m 10 -H "Title: $title" -d "$body" "https://ntfy.sh/${GSD_LITE_NTFY_TOPIC:?}" >/dev/null

# --- Slack Incoming Webhook ---
# jq -n --arg t "$title" --arg b "$body" '{text: ($t + "\n" + $b)}' |
#   curl -fsS -m 10 -H 'Content-Type: application/json' -d @- "${GSD_LITE_SLACK_WEBHOOK:?}" >/dev/null

# --- メール（mail コマンドが使える環境）---
# printf '%s\n' "$body" | mail -s "$title" "${GSD_LITE_NOTIFY_EMAIL:?}"

# --- デスクトップ通知（ローカルで動かしているとき）---
# notify-send "$title" "$body"

# どれも選んでいなければログにだけ残す（ループの標準エラー = 通常は .gsd-lite/logs/loop.log）
echo "$title — $body" >&2
