#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# validate-workflow.sh — 提交前自检（Linux 沙箱 / 本地都能跑）
#
# 做的事：
#   1. YAML 能否解析，job / step 结构是否符合预期
#   2. 工作流里引用的每个 scripts/*.ps1 是否真的存在
#   3. 每段 pwsh 的 run: 片段能否通过 PowerShell 语法解析（GHA 表达式先替换掉）
#   4. 几条踩过的坑是否有回归：Qt6 不接受的参数、fail-fast、产物上传、自检步骤
#
# 用法: bash scripts/validate-workflow.sh
# ---------------------------------------------------------------------------
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
WF=".github/workflows/build-qt-static.yml"
FAIL=0

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo "== 1. YAML 结构 =="
if python3 - "$WF" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding='utf-8'))
jobs = d.get('jobs', {})
for j in ('prepare', 'matrix', 'release'):
    assert j in jobs, f'缺少 job: {j}'
trig = d.get(True) or d.get('on')
assert 'workflow_dispatch' in trig, '缺少 workflow_dispatch'
print('  jobs:  ', ', '.join(jobs))
print('  inputs:', ', '.join(trig['workflow_dispatch']['inputs']))
PY
then pass "YAML 解析与 job 结构"; else fail "YAML 解析失败"; fi

echo "== 2. 引用的脚本是否都存在 =="
for s in $(grep -oE '\./scripts/[a-zA-Z0-9_-]+\.ps1' "$WF" | sort -u); do
  if [ -f "$s" ]; then pass "存在 $s"; else fail "缺少 $s"; fi
done

echo "== 3. 每段 pwsh 片段的语法 =="
if command -v pwsh >/dev/null 2>&1; then
  python3 - "$WF" <<'PY' > /tmp/wf_snippets.txt
import sys, yaml, re
d = yaml.safe_load(open(sys.argv[1], encoding='utf-8'))
for jn, job in d['jobs'].items():
    for i, st in enumerate(job.get('steps', [])):
        if st.get('shell') != 'pwsh' or 'run' not in st:
            continue
        code = re.sub(r'\$\{\{[^}]*\}\}', '0', st['run'])
        print(f'===CASE=== {jn}|{i}|{st.get("name", "(no name)")}')
        print(code)
PY

  python3 - <<'PY'
import subprocess, tempfile, os, sys
cases, cur = [], None
for line in open('/tmp/wf_snippets.txt', encoding='utf-8'):
    if line.startswith('===CASE=== '):
        cur = {'meta': line[len('===CASE=== '):].strip(), 'code': []}
        cases.append(cur)
    elif cur is not None:
        cur['code'].append(line)
bad = 0
for c in cases:
    with tempfile.NamedTemporaryFile('w', suffix='.ps1', delete=False, encoding='utf-8') as f:
        f.write(''.join(c['code'])); path = f.name
    cmd = ("$e=$null;$t=$null;"
           f"[System.Management.Automation.Language.Parser]::ParseFile('{path}',[ref]$t,[ref]$e)|Out-Null;"
           "if($e.Count -gt 0){$e|%{Write-Output $_.Message};exit 1}")
    r = subprocess.run(['pwsh', '-NoProfile', '-Command', cmd], capture_output=True, text=True)
    name = c['meta'].split('|')[-1]
    if r.returncode == 0:
        print(f'  \033[32mPASS\033[0m {name}')
    else:
        print(f'  \033[31mFAIL\033[0m {name}: {r.stdout.strip()}')
        bad += 1
    os.unlink(path)
sys.exit(1 if bad else 0)
PY
  if [ $? -eq 0 ]; then pass "全部 pwsh 片段语法"; else fail "有 pwsh 片段语法错误"; fi
else
  echo "  SKIP 未安装 pwsh"
fi

echo "== 4. 关键规则 =="
# 只看真正会执行的代码，注释里提到这些反模式（说明为什么不能用）不算违规
python3 - "$WF" <<'PY' > /tmp/wf_code.txt
import sys, yaml, re
d = yaml.safe_load(open(sys.argv[1], encoding='utf-8'))
out = []
for job in d['jobs'].values():
    for st in job.get('steps', []):
        if 'run' not in st:
            continue
        for line in st['run'].splitlines():
            if line.strip().startswith('#'):
                continue
            out.append(line)
print('\n'.join(out))
PY

grep -q 'fail-fast: false' "$WF" && pass "fail-fast: false" || fail "fail-fast 未关闭"
grep -q 'if-no-files-found: error' "$WF" && pass "artifact 缺失即失败" || fail "upload-artifact 未设 if-no-files-found"
grep -q 'verify-install.ps1' "$WF" && pass "有安装校验" || fail "缺少 verify-install"
grep -q 'smoke-test.ps1' "$WF" && pass "有静态链接自检" || fail "缺少 smoke-test"
grep -q 'timeout-minutes' "$WF" && pass "有超时保护" || fail "缺少 timeout-minutes"

# 下面两条是实测出来的硬坑：Qt6 的 configure 解析器会直接报 Unknown command line option
if grep -qE -- '-module-' /tmp/wf_code.txt; then
  fail "出现 -module-<x>（Qt6 configure 不支持）"
else
  pass "没有 -module-<x>"
fi
if grep -qE -- '-static-runtime=' /tmp/wf_code.txt; then
  fail "出现 -static-runtime=xxx（Qt6 只接受 -static-runtime / -no-static-runtime）"
else
  pass "static-runtime 用法正确"
fi
if grep -q -- '-opengl' /tmp/wf_code.txt; then
  pass "Qt5 静态构建显式指定了 GL 后端"
else
  fail "Qt5 静态构建缺 -opengl desktop（dynamic 与 -static 冲突）"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "全部检查通过。"
  exit 0
else
  echo "$FAIL 项检查失败。"
  exit 1
fi
