#!/usr/bin/env bash
#
# leclite 安装器：把仓库装到 /opt/leclite 并注册全局命令 lec
#
# 与常见"curl | sudo bash"的区别：
#   · 支持 --verify，用同目录下的 SHA256SUMS 校验主脚本后再安装
#   · 不删除已有目录，除非显式 --force
#   · 不改动任何系统配置文件，只装一个命令

set -uo pipefail

APP_HOME="${LECLITE_HOME:-/opt/leclite}"
BIN_PATH="/usr/local/bin/lec"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
FORCE=0
VERIFY=0
NO_CHECKOUT=0

usage() {
    cat <<EOF
用法: install.sh [选项]

  --force        覆盖已存在的 $APP_HOME
  --verify       用同目录 SHA256SUMS 校验 leclite.sh
  --bin-only     只注册命令（用于本地开发，指向当前目录）
  -h, --help     显示帮助

安装位置: $APP_HOME
命令入口: $BIN_PATH
EOF
}

for arg in "$@"; do
    case "$arg" in
        --force)    FORCE=1 ;;
        --verify)   VERIFY=1 ;;
        --bin-only) NO_CHECKOUT=1 ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "未知参数: $arg" >&2; usage; exit 1 ;;
    esac
done

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "需要 root: sudo $0" >&2
    exit 1
fi

if [[ ! -f "$SRC_DIR/leclite.sh" ]]; then
    echo "找不到 $SRC_DIR/leclite.sh —— 请在仓库根目录运行" >&2
    exit 1
fi

if (( VERIFY )); then
    if [[ ! -f "$SRC_DIR/SHA256SUMS" ]]; then
        echo "缺少 SHA256SUMS，无法校验" >&2
        exit 1
    fi
    expected=$(awk '/leclite\.sh/{print $1; exit}' "$SRC_DIR/SHA256SUMS")
    actual=$(sha256sum "$SRC_DIR/leclite.sh" | awk '{print $1}')
    if [[ "$expected" != "$actual" ]]; then
        echo "校验失败" >&2
        echo "  期望: $expected" >&2
        echo "  实际: $actual" >&2
        exit 1
    fi
    echo "[ OK ] leclite.sh SHA256 校验通过"
fi

if (( NO_CHECKOUT )); then
    target="$SRC_DIR"
else
    target="$APP_HOME"
    if [[ -d "$target" ]] && (( ! FORCE )); then
        echo "$target 已存在。升级请用: cd $target && git pull" >&2
        echo "确需覆盖请加 --force" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$target")" || exit 1
    if [[ -d "$target" ]] && (( FORCE )); then
        ts=$(date +%Y%m%d_%H%M%S)
        mv "$target" "${target}.bak.${ts}" || exit 1
        echo "[ .. ] 旧目录已改名: ${target}.bak.${ts}"
    fi
    cp -a "$SRC_DIR" "$target" || exit 1
    rm -rf "$target/.git" 2>/dev/null || true

    # 关键：这个目录里的脚本会以 root 执行，必须归 root 所有且普通用户不可写。
    # 否则任何能写该目录的账号（或被盗用的账号）都能往脚本里塞一行拿到 root。
    chown -R root:root "$target" 2>/dev/null || true
    chmod -R go-w "$target" 2>/dev/null || true
    echo "[ OK ] 已安装到 $target（属主 root，组/其他不可写）"
fi

chmod +x "$target/leclite.sh" || exit 1

# 注意：这里刻意不用 sudo -E。
# -E 会把调用者的环境变量带进 root 进程，等于给 BASH_ENV / LD_PRELOAD 之类开了门：
#   BASH_ENV=/tmp/evil.sh lec   → root 的 bash 会 source /tmp/evil.sh
# 用 sudo -- 结束选项解析，环境由 sudoers 的 env_reset 重置。
cat >"$BIN_PATH" <<EOF
#!/usr/bin/env bash
exec sudo -- bash "$target/leclite.sh" "\$@"
EOF
chmod 755 "$BIN_PATH" || exit 1

echo "[ OK ] 已注册命令: $BIN_PATH"
echo
echo "  直接输入  lec  启动菜单"
echo "  只读检查  lec info"
echo "  演练模式  lec --dry-run apt auto"
