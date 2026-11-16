#!/usr/bin/env bash
# lapis-mt6878-root — one-shot root for Redmi Note 15 Pro 5G (lapis / MT6878)
# 用法: bash scripts/root.sh [--ksud /path/to/ksud]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TIMER="$ROOT/bin/timer-fullroot"
KSUD_LOCAL=""
KSUD_URL="https://github.com/tiann/KernelSU/releases/download/v3.3.1/ksud-aarch64-linux-android"

while [ $# -gt 0 ]; do
  case "$1" in
    --ksud) KSUD_LOCAL="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

die() { echo "[-] $*" >&2; exit 1; }
step() { echo; echo "=== $* ==="; }

adb get-state >/dev/null 2>&1 || die "no adb device. connect USB + enable USB debugging"

step "1/5 检查设备状态"
adb shell getprop ro.build.version.incremental
adb shell uname -r
LOCKED=$(adb shell getprop ro.boot.flash.locked | tr -d '\r')
echo "bootloader flash.locked = $LOCKED"
[ "$LOCKED" = "1" ] || echo "[!] 设备已是解锁状态，本工具仍可运行"

step "2/5 推送 timer"
[ -f "$TIMER" ] || die "missing $TIMER"
adb push "$TIMER" /data/local/tmp/timer
adb shell chmod 755 /data/local/tmp/timer

step "3/5 准备 ksud (>= 3.3.1)"
if [ -n "$KSUD_LOCAL" ]; then
  adb push "$KSUD_LOCAL" /data/local/tmp/ksud
elif [ -x "$ROOT/ksud" ]; then
  adb push "$ROOT/ksud" /data/local/tmp/ksud
else
  CUR=$(adb shell '/data/local/tmp/ksud --version 2>/dev/null' | tr -d '\r' || true)
  case "$CUR" in
    3.[3-9]*|3.[1-9][0-9]*) echo "existing ksud OK: $CUR" ;;
    *)
      echo "downloading ksud 3.3.1 ..."
      TMPK=$(mktemp)
      if command -v curl >/dev/null; then curl -L -o "$TMPK" "$KSUD_URL"
      else wget -O "$TMPK" "$KSUD_URL"; fi
      adb push "$TMPK" /data/local/tmp/ksud
      rm -f "$TMPK"
      ;;
  esac
fi
adb shell chmod 755 /data/local/tmp/ksud
adb shell '/data/local/tmp/ksud --version'

step "4/5 执行 exploit（约 40 秒，请勿操作手机）"
adb shell 'rm -f /data/local/tmp/t.log /data/local/tmp/ksu_stage.sh'
adb shell 'cd /data/local/tmp; nohup ./timer fake >t.log 2>&1 </dev/null & echo started'

for i in $(seq 1 30); do
  sleep 3
  OUT=$(adb shell 'grep -cE "KSU_LOADED|KSU_MISSING|parking without reap" /data/local/tmp/t.log 2>/dev/null' | tr -d '\r' || echo 0)
  [ "${OUT:-0}" -gt 0 ] && break
  printf '.'
done
echo

step "5/5 结果"
adb shell 'grep -E "selinux|ksud=|late-load|KSU_" /data/local/tmp/t.log' || true
echo
echo "--- verify ---"
if adb shell 'su -c id' 2>/dev/null; then
  echo
  echo "[+] ROOT OK"
  echo "    软重启保留: adb shell \"su -c 'stop; start'\""
  echo "    冷启动后需重新执行本脚本"
else
  echo "[-] su 不可用。查看 /data/local/tmp/t.log"
  echo "    常见原因: ksud < 3.3.1 / KMI 不匹配 / SELinux 未成功关闭"
  exit 1
fi
