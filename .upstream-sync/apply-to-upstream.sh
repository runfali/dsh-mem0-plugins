#!/usr/bin/env bash
# dsh-mem0-plugins — 把本轮 DSH 0.1.5-rc.1 适配同步到上游 mem0_falkordb 仓。
#
# 为什么需要这个脚本：本次执行环境的文件沙箱是 workspace-write，工作区外的
# /data/code（上游 mem0_falkordb 检出）不可写，故同步动作交由此脚本在沙箱外执行。
#
# 用法：
#   bash .upstream-sync/apply-to-upstream.sh                    # 预览（默认，不动任何文件）
#   bash .upstream-sync/apply-to-upstream.sh --apply            # 真同步 + 装依赖 + 跑全量测试
#   UPSTREAM=/path/to/other bash .../apply-to-upstream.sh       # 指定其它上游路径
#
# 同步源一律取工作区副本的上层目录（$HERE/..），不留任何文件快照，避免双份漂移。
#
# 同步面（镜像工作区副本；按既定约定**跳过**副本差异文件：双语 README /
# cordis.patch.yml 英文注释版 / COMPARISON.md 脱敏版 / 独立截图集）：
#   src/*.js            ← 逐字节相同（脚本校验并报告，不重复写）
#   test/*.mjs          ← 新增 entry.test.mjs；其余逐字节相同
#   lib/client.js       ← requestTimeoutMs 文案漂移修复（300000 → 420000）
#   pnpm-workspace.yaml ← minimumReleaseAgeExclude 刷到 0.1.5-rc.1（16 条）
#   package.json        ← version 0.2.0→0.2.1、依赖 ^0.1.5-rc.1、dsh.engines.dsh、scripts.test
#   docs/AUDIT.md       ← Round 5 全录
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$HERE/.." && pwd)"
UPSTREAM="${UPSTREAM:-/data/code/mem0_falkordb/plugins/dsh-mem0-plugins}"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

[ -d "$UPSTREAM" ] || { echo "上游目录不存在: $UPSTREAM" >&2; exit 1; }
echo "== 源:   $SRC"
echo "== 上游: $UPSTREAM"
echo "== 模式: $([ $APPLY -eq 1 ] && echo 应用 || echo 预览（加 --apply 真同步）)"
echo

sync_file() { # $1 = 相对路径（两侧同构）
  local rel="$1" from="$SRC/$1" to="$UPSTREAM/$1"
  if [ ! -f "$from" ]; then echo "  源缺失，跳过 $rel"; return 0; fi
  if [ -f "$to" ] && cmp -s "$from" "$to"; then echo "  同   $rel"; return 0; fi
  if [ $APPLY -eq 1 ]; then
    mkdir -p "$(dirname "$to")"
    cp "$from" "$to"
    echo "  写入 $rel"
  else
    echo "  待写 $rel"
  fi
}

echo "-- 源码 --"
for f in src/index.js src/backend.js src/coalesce.js src/distill.js src/formatting.js src/guards.js src/redact.js; do sync_file "$f"; done
echo "-- 测试（含新增 entry-smoke）--"
for f in test/entry.test.mjs test/smoke.mjs test/client-smoke.mjs test/formatting.test.mjs test/redact.test.mjs; do sync_file "$f"; done
echo "-- 浏览器半与依赖白名单 --"
sync_file lib/client.js
sync_file pnpm-workspace.yaml

echo "-- package.json（版本号走上游自有序列，不套用副本的 0.1.5-rc.1）--"
if [ $APPLY -eq 1 ]; then
  UPSTREAM_PKG="$UPSTREAM" python3 - <<'PY'
import json, collections, os
p = os.path.join(os.environ['UPSTREAM_PKG'], 'package.json')
d = json.load(open(p), object_pairs_hook=collections.OrderedDict)
d['version'] = '0.2.1'
d['dependencies'] = collections.OrderedDict([
    ('@deepseek-ai/dsh-settings', '^0.1.5-rc.1'),
    ('@deepseek-ai/dsh-tools', '^0.1.5-rc.1'),
    ('@deepseek-ai/schemastery', '^3.18.2'),
])
out = collections.OrderedDict()
for k, v in d.items():
    out[k] = v
    if k == 'keywords':
        out['scripts'] = {'test': 'node --test test/*.test.mjs && node test/smoke.mjs && node test/client-smoke.mjs'}
dsh = out['dsh']
merged = collections.OrderedDict()
merged['engines'] = {'dsh': '>=0.1.2-alpha.3 <0.2.0 || >=0.1.5-alpha.1 <0.1.6'}
for k, v in dsh.items():
    merged[k] = v
out['dsh'] = merged
open(p, 'w').write(json.dumps(out, indent=2, ensure_ascii=False) + chr(10))
print('  package.json 已更新：version=0.2.1 / deps ^0.1.5-rc.1 / dsh.engines.dsh / scripts.test')
PY
else
  echo "  待改 package.json（version=0.2.1 / deps ^0.1.5-rc.1 / dsh.engines.dsh / scripts.test）"
fi

echo "-- 审计报告 --"
sync_file docs/AUDIT.md

echo
if [ $APPLY -eq 0 ]; then
  echo "预览完成，未改动任何文件。加 --apply 真同步。"
  exit 0
fi

echo "== 校验声明 =="
( cd "$UPSTREAM" && node -e "const p=require('./package.json'); console.log('version       ', p.version); console.log('engines.dsh   ', p.dsh.engines.dsh); console.log('deps          ', JSON.stringify(p.dependencies)); console.log('scripts.test  ', p.scripts.test)" )

echo "-- 依赖同步（需联网。CI=true 规避无 TTY 下 pnpm 中止清 node_modules）--"
if command -v pnpm >/dev/null 2>&1; then
  ( cd "$UPSTREAM" && CI=true pnpm install --no-frozen-lockfile 2>&1 | tail -5 ) || echo "  pnpm install 失败（离线？）—— 源码与声明已就位，稍后重试"
fi

echo "-- 全量测试（必须在 0.1.5-rc.1 真实依赖下跑）--"
if [ -d "$UPSTREAM/node_modules/@deepseek-ai/dsh-tools" ]; then
  v=$(node -e "console.log(require('$UPSTREAM/node_modules/@deepseek-ai/dsh-tools/package.json').version)")
  echo "  dsh-tools 实测版本: $v"
  ( cd "$UPSTREAM" && node --test test/*.test.mjs 2>&1 | grep -E '^# (tests|pass|fail)|^ℹ (tests|pass|fail)' )
  ( cd "$UPSTREAM" && node test/smoke.mjs 2>&1 | tail -2 )
  ( cd "$UPSTREAM" && node test/client-smoke.mjs 2>&1 | tail -2 )
else
  echo "  跳过：node_modules 未就绪"
fi

echo
echo "== git 提交（逐项，便于回滚；注意根 .gitignore 第 25 行的泛化 lib/ 规则）=="
echo "  cd /data/code/mem0_falkordb"
echo "  git add plugins/dsh-mem0-plugins"
echo "  git add -f plugins/dsh-mem0-plugins/lib/client.js   # 被 lib/ 规则挡住时才需要 -f"
echo "  git commit -m 'fix(plugins): adapt dsh-mem0-plugins to dsh 0.1.5-rc.1（engines 区间/文案漂移/entry-smoke）'"
echo "同步完成。"
