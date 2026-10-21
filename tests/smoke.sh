#!/usr/bin/env bash
#
# 冒烟测试：只验证"参数解析 + 退出码 + 输出约定"，
# 除 dry-run 用例会触碰 /var/backups 之外不改动系统，
# 可在 CI 与本地反复跑。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
SH="$ROOT/leclite.sh"
PASS=0
FAIL=0

t() {
    local name="$1" want="$2" got="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  \033[32mPASS\033[0m %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf '  \033[31mFAIL\033[0m %s (want=%s got=%s)\n' "$name" "$want" "$got"
        FAIL=$((FAIL + 1))
    fi
}

t_contains() {
    local name="$1" needle="$2" hay="$3"
    if [[ "$hay" == *"$needle"* ]]; then
        printf '  \033[32mPASS\033[0m %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf '  \033[31mFAIL\033[0m %s (missing: %s)\n' "$name" "$needle"
        FAIL=$((FAIL + 1))
    fi
}

# 以 root 跑：已经是 root 直接跑，否则 sudo -n；都拿不到返回 77 表示跳过
run_root() {
    if [[ $EUID -eq 0 ]]; then
        bash "$@"
        return $?
    fi
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        sudo -n bash "$@"
        return $?
    fi
    return 77
}

echo "[smoke] $SH"

# 1. 版本号格式
out=$(bash "$SH" --version 2>&1)
t_contains "version 含 leclite" "leclite" "$out"

# 2. help 列出关键选项
out=$(bash "$SH" --help 2>&1)
t_contains "help 含 --dry-run" "--dry-run" "$out"
t_contains "help 含 --public" "--public" "$out"

# 3. 未知命令必须非零退出
bash "$SH" nosuchcmd >/dev/null 2>&1
t "未知命令退出码" "1" "$?"

# 4. 未知子命令非零
bash "$SH" apt nosuchmirror >/dev/null 2>&1
t "未知镜像非零退出" "1" "$?"

# 5. pass 生成器：长度正确、两次不同、无默认口令痕迹
# 口令在 stderr、带前导空格，所以用 -o 提取连续 32 位串
p1=$(bash "$SH" pass 32 2>&1 >/dev/null | grep -oE '[A-Za-z0-9]{32}' | head -1)
p2=$(bash "$SH" pass 32 2>&1 >/dev/null | grep -oE '[A-Za-z0-9]{32}' | head -1)
t "pass 生成长度32" "32" "${#p1}"
if [[ -n $p1 && "$p1" != "$p2" ]]; then
    printf '  \033[32mPASS\033[0m pass 两次结果不同\n'
    PASS=$((PASS + 1))
else
    printf '  \033[31mFAIL\033[0m pass 两次结果相同或为空\n'
    FAIL=$((FAIL + 1))
fi

# 6. Linux 才跑系统相关部分
if [[ "$(uname -s)" == "Linux" ]]; then
    # dry-run 不能改文件：抓 sources.list 与 deb822 的 mtime
    snap_before=""
    [[ -f /etc/apt/sources.list ]] && snap_before=$(stat -c %Y /etc/apt/sources.list 2>/dev/null)
    deb822_before=""
    for f in /etc/apt/sources.list.d/*.sources; do
        [[ -f $f ]] || continue
        deb822_before+="$(basename "$f"):$(stat -c %Y "$f" 2>/dev/null);"
    done

    out=$(run_root "$SH" --dry-run --yes apt tsinghua 2>&1)
    rc=$?
    if [[ $rc -eq 77 ]]; then
        printf '  \033[33mSKIP\033[0m dry-run 用例（需要 root 或免密 sudo）\n'
    else
        t "dry-run 退出码" "0" "$rc"
        t_contains "dry-run 输出 [dry-run]" "[dry-run]" "$out"
        t_contains "dry-run 报告了备份动作" "备份" "$out"
    fi

    snap_after=""
    [[ -f /etc/apt/sources.list ]] && snap_after=$(stat -c %Y /etc/apt/sources.list 2>/dev/null)
    t "dry-run 未修改 sources.list" "$snap_before" "$snap_after"

    deb822_after=""
    for f in /etc/apt/sources.list.d/*.sources; do
        [[ -f $f ]] || continue
        deb822_after+="$(basename "$f"):$(stat -c %Y "$f" 2>/dev/null);"
    done
    t "dry-run 未修改 deb822 源" "$deb822_before" "$deb822_after"

    # info 只读，退出码 0
    bash "$SH" info >/dev/null 2>&1
    t "info 退出码" "0" "$?"

    # doctor 只读：0=全通过，1=有致命项，两者都合法；>1 说明脚本崩了
    bash "$SH" doctor >/dev/null 2>&1
    rc=$?
    if [[ $rc -le 1 ]]; then
        printf '  \033[32mPASS\033[0m doctor 正常退出(rc=%s)\n' "$rc"
        PASS=$((PASS + 1))
    else
        printf '  \033[31mFAIL\033[0m doctor 异常退出(rc=%s)\n' "$rc"
        FAIL=$((FAIL + 1))
    fi
else
    printf '  \033[33mSKIP\033[0m 非 Linux，跳过系统相关用例\n'
fi

echo
echo "[smoke] PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
