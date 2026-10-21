#!/usr/bin/env bash
#
# leclite - 轻量 Linux 安全环境配置器
#
# 设计取舍（与常见的"一键全家桶"相反）：
#   1. 不自更新：脚本永远不会从网络覆盖自己。升级靠 git/包管理器，人工触发。
#   2. 无默认口令：所有服务口令随机生成，写 0600 的 .env，只在终端打印一次。
#   3. 默认只听 127.0.0.1：暴露到 0.0.0.0 需要显式 --public，且会二次确认。
#   4. 写系统文件前必快照：/var/backups/leclite/<时间戳>/，带 manifest 可一键回滚。
#   5. 不开 set -e：交互脚本里 set -e 会把"某条命令失败"升级成"整个程序消失"，
#      这里改为显式判断返回值 + ERR trap 记录现场，失败就地降级不中断。
#
# License: MIT

set -uo pipefail

readonly APP="leclite"
readonly VERSION="1.1.1"
readonly APP_HOME_DEFAULT="/opt/leclite"
readonly BIN_PATH="/usr/local/bin/lec"

APP_HOME="${LECLITE_HOME:-$APP_HOME_DEFAULT}"
BACKUP_ROOT="${LECLITE_BACKUP_ROOT:-/var/backups/leclite}"
LOG_DIR="${LECLITE_LOG_DIR:-/var/log/leclite}"
LAB_ROOT="${LECLITE_LAB_ROOT:-$APP_HOME/labs}"

DRY_RUN=0
ASSUME_YES=0
DEBUG=0
PUBLIC_BIND=0
SNAP_DIR=""

# ────────────────────────────────────────────────────────────────
# 输出层
# ────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
    C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[34m'
    C_M=$'\033[35m'; C_C=$'\033[36m'; C_W=$'\033[37m'; C_GRAY=$'\033[90m'
    C_BG=$'\033[92m'; C_BD=$'\033[1m'; C_0=$'\033[0m'
else
    C_R=''; C_G=''; C_Y=''; C_B=''; C_M=''; C_C=''; C_W=''; C_GRAY=''
    C_BG=''; C_BD=''; C_0=''
fi

_log() {
    (( DEBUG )) || return 0
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"${LOG_DIR}/debug.log" 2>/dev/null || true
}

info()  { printf '  %s[ .. ]%s %s\n' "$C_B"  "$C_0" "$*" >&2; _log "INFO $*"; }
ok()    { printf '  %s[ OK ]%s %s\n' "$C_G"  "$C_0" "$*" >&2; _log "OK   $*"; }
warn()  { printf '  %s[WARN]%s %s\n' "$C_Y"  "$C_0" "$*" >&2; _log "WARN $*"; }
err()   { printf '  %s[FAIL]%s %s\n' "$C_R"  "$C_0" "$*" >&2; _log "ERR  $*"; }
note()  { printf '  %s%s%s\n' "$C_GRAY" "$*" "$C_0" >&2; }

hr() {
    local w=64 i line
    line=""
    for ((i = 0; i < w; i++)); do line+="─"; done
    printf '  %s%s%s\n' "$C_GRAY" "$line" "$C_0" >&2
}

title() {
    local text="$*" w=64 pad
    pad=$(( (w - ${#text}) / 2 ))
    (( pad < 0 )) && pad=0
    printf '\n  %s%s%s\n' "$C_BG$C_BD" "$(printf '%*s' "$pad" '')${text}" "$C_0" >&2
    hr
}

section() {
    printf '\n  %s▸ %s%s%s\n' "$C_BG" "$C_BD" "$*" "$C_0" >&2
    hr
}

die() { err "$*"; exit 1; }

# ────────────────────────────────────────────────────────────────
# 错误诊断（ERR trap：只记录，不终止）
# ────────────────────────────────────────────────────────────────

_on_err() {
    local code=$1 cmd=${BASH_COMMAND:-unknown} loc
    loc="${BASH_SOURCE[1]##*/}:${BASH_LINENO[0]:-0}"
    {
        mkdir -p "$LOG_DIR" 2>/dev/null
        printf '[%s] code=%s at %s cmd=%s\n' \
            "$(date '+%F %T')" "$code" "$loc" "$cmd"
    } >>"$LOG_DIR/error.log" 2>/dev/null || true
    _log "ERR code=$code at $loc cmd=$cmd"
}
trap '_on_err $?' ERR

_on_exit() {
    if [[ -n "${SNAP_DIR:-}" && -d "$SNAP_DIR" ]]; then
        note "本次改动快照: $SNAP_DIR  （回滚: lec backup restore）"
    fi
}
trap '_on_exit' EXIT

# ────────────────────────────────────────────────────────────────
# 基础能力
# ────────────────────────────────────────────────────────────────

have() { command -v "$1" >/dev/null 2>&1; }

need_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] && return 0
    err "这个操作需要 root：sudo $0"
    return 1
}

# 统一的执行入口：dry-run 只打印，不发车
run() {
    if (( DRY_RUN )); then
        printf '  %s[dry-run]%s %s\n' "$C_Y" "$C_0" "$*" >&2
        return 0
    fi
    _log "CMD $*"
    "$@"
}

# 需要管道/重定向时用（参数是 shell 片段）
run_sh() {
    local src="$1"
    if (( DRY_RUN )); then
        printf '  %s[dry-run]%s %s\n' "$C_Y" "$C_0" "$src" >&2
        return 0
    fi
    _log "SH $src"
    bash -c "$src"
}

confirm() {
    local prompt="${1:-继续?}"
    (( ASSUME_YES )) && { note "--yes 已指定，跳过确认: $prompt"; return 0; }
    local ans
    while true; do
        printf '  %s??%s %s %s[y/N]%s ' "$C_M" "$C_0" "$prompt" "$C_BD" "$C_0" >&2
        if ! read -r ans; then
            printf '\n' >&2
            warn "输入流结束，退出"
            exit 0
        fi
        case "$ans" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]|"") return 1 ;;
            *) warn "请输入 y 或 n" ;;
        esac
    done
}

ask() {
    local prompt="$1" default="${2:-}" out
    (( ASSUME_YES )) && { printf '%s' "$default"; return 0; }
    printf '  %s->%s %s ' "$C_C" "$C_0" "$prompt" >&2
    if ! read -r out; then
        printf '\n' >&2
        exit 0
    fi
    [[ -z $out ]] && out="$default"
    printf '%s' "$out"
}

ask_secret() {
    local prompt="$1" out
    printf '  %s->%s %s ' "$C_C" "$C_0" "$prompt" >&2
    if ! read -rs out; then
        printf '\n' >&2
        exit 0
    fi
    printf '\n' >&2
    printf '%s' "$out"
}

pause() {
    (( ASSUME_YES )) && return 0
    printf '  %s按回车继续...%s' "$C_GRAY" "$C_0" >&2
    read -r _ || exit 0
}

page_break() { printf '\n' >&2; }

# 随机口令：只取字母数字，默认 24 位。只读 /dev/urandom，不落盘。
gen_pass() {
    local len="${1:-24}" raw
    [[ $len =~ ^[0-9]+$ ]] || len=24
    (( len < 8 )) && len=8
    raw=$(head -c $((len * 8 + 256)) /dev/urandom 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' || true)
    if [[ ${#raw} -lt $len ]]; then
        # /dev/urandom 不可用时的兜底
        raw=$(printf '%s' "$(date +%s%N)$$$RANDOM$RANDOM$RANDOM$RANDOM" | sha256sum | cut -c1-64)
    fi
    printf '%s' "${raw:0:$len}"
}

# ────────────────────────────────────────────────────────────────
# 快照 / 回滚
# ────────────────────────────────────────────────────────────────

snap_begin() {
    [[ -n ${SNAP_DIR:-} ]] && return 0
    SNAP_DIR="$BACKUP_ROOT/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$SNAP_DIR" 2>/dev/null || { err "无法创建快照目录: $SNAP_DIR"; return 1; }
    : >"$SNAP_DIR/manifest" 2>/dev/null || true
    _log "SNAP begin $SNAP_DIR"
}

# 备份单个文件/目录，并把"原路径 -> 备份名"写进 manifest
snap_file() {
    local src="$1" base
    [[ -e $src ]] || return 0
    if (( DRY_RUN )); then
        printf '  %s[dry-run]%s 备份 %s\n' "$C_Y" "$C_0" "$src" >&2
        return 0
    fi
    snap_begin || return 1
    base=$(printf '%s' "$src" | sed 's|^/||; s|/|__|g')
    cp -a "$src" "$SNAP_DIR/$base" 2>/dev/null || { warn "备份失败: $src"; return 1; }
    printf '%s\t%s\n' "$src" "$base" >>"$SNAP_DIR/manifest"
    _log "SNAP file $src -> $base"
    return 0
}

snap_list() {
    [[ -d $BACKUP_ROOT ]] || { note "还没有任何快照"; return 0; }
    local d found=0
    for d in "$BACKUP_ROOT"/*/; do
        [[ -d $d ]] || continue
        found=1
        printf '  %s%s%s  %s\n' "$C_C" "$(basename "$d")" "$C_0" \
            "$(wc -l <"$d/manifest" 2>/dev/null || echo 0) 个文件" >&2
    done
    (( found )) || note "还没有任何快照"
}

snap_restore() {
    need_root || return 1
    snap_list
    local ts
    ts=$(ask "要恢复哪个快照(时间戳)" "")
    [[ -z $ts ]] && return 1
    local dir="$BACKUP_ROOT/$ts"
    [[ -f "$dir/manifest" ]] || { err "快照不存在或已损坏: $dir"; return 1; }

    section "恢复快照 $ts"
    local src base
    while IFS=$'\t' read -r src base; do
        [[ -n ${src:-} ]] || continue
        printf '    %s -> %s\n' "$base" "$src" >&2
    done <"$dir/manifest"

    confirm "确认把这些文件恢复到系统?" || return 1
    while IFS=$'\t' read -r src base; do
        [[ -n ${src:-} ]] || continue
        if run cp -a "$dir/$base" "$src"; then
            ok "已恢复 $src"
        else
            err "恢复失败 $src"
        fi
    done <"$dir/manifest"

    if [[ -f /etc/apt/sources.list.d ]] || [[ -e /etc/apt/sources.list ]]; then
        have apt-get && { info "刷新包索引..."; run apt-get update -qq || warn "apt update 失败"; }
    fi
    have systemctl && run systemctl daemon-reload >/dev/null 2>&1 || true
    ok "恢复完成"
}

# ────────────────────────────────────────────────────────────────
# 系统信息
# ────────────────────────────────────────────────────────────────

detect_os() {
    OS_ID="unknown"; OS_CODENAME=""; OS_NAME="unknown"; OS_VER="unknown"; OS_LIKE=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
        OS_NAME="${PRETTY_NAME:-${NAME:-unknown}}"
        OS_VER="${VERSION_ID:-unknown}"
        OS_LIKE="${ID_LIKE:-}"
    fi
    case "$OS_ID" in
        ubuntu|kali|debian) return 0 ;;
        *)
            if [[ ${OS_LIKE} =~ (debian|ubuntu) ]]; then return 0; fi
            return 1
            ;;
    esac
}

require_supported_os() {
    if ! detect_os; then
        err "仅支持 Ubuntu / Debian / Kali（当前: $OS_NAME）"
        return 1
    fi
    if [[ -z $OS_CODENAME && $OS_ID != kali ]]; then
        err "无法确定发行版代号(VERSION_CODENAME)，换源与装源会失败"
        return 1
    fi
    return 0
}

arch() { dpkg --print-architecture 2>/dev/null || uname -m; }

best_ip() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    printf '%s' "${ip:-127.0.0.1}"
}

cmd_info() {
    require_supported_os || true
    title "$APP v$VERSION 系统自检"
    printf '  %s操作系统%s  %s\n'      "$C_W" "$C_0" "$OS_NAME"
    printf '  %s发行版%s    %s %s (%s)\n' "$C_W" "$C_0" "$OS_ID" "${OS_VER:--}" "${OS_CODENAME:--}"
    printf '  %s架构%s      %s\n'      "$C_W" "$C_0" "$(arch)"
    printf '  %s内核%s      %s\n'      "$C_W" "$C_0" "$(uname -r)"
    printf '  %s内存%s      %s\n'      "$C_W" "$C_0" "$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')"
    printf '  %s根分区%s    %s 已用 %s\n' "$C_W" "$C_0" \
        "$(df -h / 2>/dev/null | awk 'NR==2{print $2}')" \
        "$(df -h / 2>/dev/null | awk 'NR==2{print $5}')"
    printf '  %s内网地址%s  %s\n'    "$C_W" "$C_0" "$(best_ip)"
    printf '  %s运行身份%s  %s\n'    "$C_W" "$C_0" "$(id -un) (uid=$(id -u))"
    hr
    printf '  %s依赖检查%s\n' "$C_W" "$C_0"
    local c miss=0
    for c in curl wget git jq unzip docker; do
        if have "$c"; then
            printf '    %s✔%s %-8s %s\n' "$C_G" "$C_0" "$c" "$(command -v "$c")" >&2
        else
            printf '    %s─%s %-8s %s缺%s\n' "$C_GRAY" "$C_0" "$c" "$C_Y" "$C_0" >&2
            miss=$((miss + 1))
        fi
    done
    page_break
    if (( miss > 0 )); then
        note "缺失 $miss 项，可在菜单[4 工具链]里补齐"
    else
        ok "依赖齐备"
    fi
    if [[ -d $BACKUP_ROOT ]]; then
        page_break
        info "最近快照:"; snap_list
    fi
}

# ────────────────────────────────────────────────────────────────
# APT 换源（兼容 deb822 与老式 sources.list）
# ────────────────────────────────────────────────────────────────

declare -A MIRROR_BASE=(
    [aliyun]="https://mirrors.aliyun.com"
    [tencent]="https://mirrors.cloud.tencent.com"
    [huawei]="https://repo.huaweicloud.com"
    [tsinghua]="https://mirrors.tuna.tsinghua.edu.cn"
    [ustc]="https://mirrors.ustc.edu.cn"
)
declare -A MIRROR_LABEL=(
    [aliyun]="阿里云" [tencent]="腾讯云" [huawei]="华为云"
    [tsinghua]="清华大学" [ustc]="中科大" [official]="官方源"
)

official_base() {
    case "$OS_ID" in
        ubuntu) printf 'http://archive.ubuntu.com' ;;
        debian) printf 'http://deb.debian.org' ;;
        kali)   printf 'http://http.kali.org' ;;
        *)      printf 'http://archive.ubuntu.com' ;;
    esac
}

resolve_base() {
    local name="$1"
    if [[ $name == official ]]; then
        official_base
    else
        printf '%s' "${MIRROR_BASE[$name]:-}"
    fi
}

# 列出 deb822 源文件
deb822_files() {
    local f
    for f in /etc/apt/sources.list.d/*.sources; do
        [[ -f $f ]] || continue
        printf '%s\n' "$f"
    done
}

# 测速：拉 Release 头，取 time_total 最小的
mirror_latency() {
    local base="$1" path t
    case "$OS_ID" in
        ubuntu) path="/ubuntu/dists/${OS_CODENAME}/Release" ;;
        debian) path="/debian/dists/${OS_CODENAME}/Release" ;;
        kali)   path="/kali/dists/kali-rolling/Release" ;;
        *)      path="/" ;;
    esac
    t=$(curl -o /dev/null -sS -m 4 -w '%{time_total}' "${base}${path}" 2>/dev/null) || t=""
    printf '%s' "${t:-99}"
}

cmd_apt_auto() {
    need_root || return 1
    require_supported_os || return 1
    section "自动测速选源"
    local name base lat best="" best_lat=99
    for name in aliyun tencent huawei tsinghua ustc; do
        base="${MIRROR_BASE[$name]}"
        printf '    %-10s %s' "$name" "${MIRROR_LABEL[$name]}" >&2
        lat=$(mirror_latency "$base")
        printf '  %ss%s\n' "$lat" "$C_0" >&2
        if awk "BEGIN{exit !($lat < $best_lat)}"; then
            best_lat=$lat; best="$name"
        fi
    done
    if [[ -z $best ]]; then
        err "所有镜像都不可达，检查网络或代理"
        return 1
    fi
    ok "最快: ${MIRROR_LABEL[$best]} (${best_lat}s)"
    apply_mirror "$best"
}

apply_mirror() {
    local name="$1" base
    base=$(resolve_base "$name")
    [[ -n $base ]] || { err "未知镜像: $name"; return 1; }

    section "切换到 ${MIRROR_LABEL[$name]:-$name}  ($base)"

    local files=() f
    while IFS= read -r f; do files+=("$f"); done < <(deb822_files)

    if (( ${#files[@]} > 0 )); then
        info "检测到 deb822 源（${#files[@]} 个文件），只替换 URI 主机，保留 Signed-By/Suites"
        for f in "${files[@]}"; do
            snap_file "$f" || return 1
            # 把 URIs: 行里任意 scheme://host 的 host 换掉，路径保留
            run sed -i -E \
                "s|(^URIs:[[:space:]]*https?://)[^/]+|\1${base#*://}|" "$f" || {
                err "写入失败: $f"; return 1; }
            printf '    %s\n' "$(grep -h '^URIs:' "$f" | head -1)" >&2
        done
    else
        info "使用老式 /etc/apt/sources.list"
        local sl=/etc/apt/sources.list
        snap_file "$sl" || return 1
        local body
        body=$(gen_sources_list "$base")
        [[ -z $body ]] && { err "无法为该发行版生成源"; return 1; }
        if run_sh "printf '%s\n' $(printf '%q' "$body") > $sl"; then
            ok "已写入 $sl"
        else
            err "写入 $sl 失败"
            return 1
        fi
        printf '%s\n' "$body" | sed 's/^/    /' >&2
    fi

    info "同步包索引..."
    if run env DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
        ok "包索引已更新"
    else
        warn "apt update 失败：源不可用或网络问题，可用 lec apt restore 回滚"
        return 1
    fi
}

gen_sources_list() {
    local base="$1"
    case "$OS_ID" in
        ubuntu)
            cat <<EOF
deb ${base}/ubuntu ${OS_CODENAME} main restricted universe multiverse
deb ${base}/ubuntu ${OS_CODENAME}-updates main restricted universe multiverse
deb ${base}/ubuntu ${OS_CODENAME}-backports main restricted universe multiverse
deb ${base}/ubuntu ${OS_CODENAME}-security main restricted universe multiverse
EOF
            ;;
        debian)
            cat <<EOF
deb ${base}/debian ${OS_CODENAME} main contrib non-free non-free-firmware
deb ${base}/debian ${OS_CODENAME}-updates main contrib non-free non-free-firmware
deb ${base}/debian-security ${OS_CODENAME}-security main contrib non-free non-free-firmware
EOF
            ;;
        kali)
            printf 'deb %s/kali kali-rolling main contrib non-free non-free-firmware\n' "$base"
            ;;
        *) return 1 ;;
    esac
}

cmd_apt() {
    local sub="${1:-}"
    case "$sub" in
        auto)      cmd_apt_auto ;;
        official)  need_root && apply_mirror official ;;
        restore)   snap_restore ;;
        aliyun|tencent|huawei|tsinghua|ustc)
            need_root && { require_supported_os && apply_mirror "$sub"; } ;;
        "")
            section "APT 源"
            local c
            printf '  1) 自动测速选最快\n  2) 阿里云\n  3) 腾讯云\n  4) 华为云\n' >&2
            printf '  5) 清华大学\n  6) 中科大\n  7) 官方源\n  8) 恢复历史快照\n  0) 返回\n' >&2
            c=$(ask "选择" "1")
            case "$c" in
                1) cmd_apt_auto ;;
                2) need_root && apply_mirror aliyun ;;
                3) need_root && apply_mirror tencent ;;
                4) need_root && apply_mirror huawei ;;
                5) need_root && apply_mirror tsinghua ;;
                6) need_root && apply_mirror ustc ;;
                7) need_root && apply_mirror official ;;
                8) snap_restore ;;
                *) return 0 ;;
            esac
            ;;
        *) err "未知子命令: apt $sub"; return 1 ;;
    esac
}

# ────────────────────────────────────────────────────────────────
# 基础配置：SSH / root / DNS / 时区
# ────────────────────────────────────────────────────────────────

set_ssh_safe() {
    need_root || return 1
    section "SSH 加固（安全默认）"
    if ! have sshd && ! dpkg -l openssh-server >/dev/null 2>&1; then
        info "安装 openssh-server"
        run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server || {
            err "安装失败"; return 1; }
    fi

    local cfg=/etc/ssh/sshd_config
    [[ -f $cfg ]] || { err "找不到 $cfg"; return 1; }
    snap_file "$cfg" || return 1

    local drop=/etc/ssh/sshd_config.d/99-leclite.conf
    snap_file "$drop" || true
    mkdir -p /etc/ssh/sshd_config.d 2>/dev/null || true

    # 用独立 drop-in 而不是 sed 主配置：可整块删除，不会改乱别人的规则
    local body="# managed by leclite
PermitRootLogin prohibit-password
PubkeyAuthentication yes
MaxAuthTries 4
LoginGraceTime 20
X11Forwarding no
"
    if run_sh "printf '%s' $(printf '%q' "$body") > $drop"; then
        ok "已写入 $drop（root 仅密钥登录、禁 X11）"
    else
        err "写入 $drop 失败"
        return 1
    fi

    if [[ -d /etc/ssh/sshd_config.d ]] && ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d' "$cfg"; then
        warn "主配置未 Include sshd_config.d，本次改动可能不生效"
        note "修法: 在 $cfg 顶部加一行  Include /etc/ssh/sshd_config.d/*.conf"
    fi

    # 关键：先语法校验，坏了就回滚，绝不把 SSH 弄死
    if have sshd; then
        if ! run sshd -t 2>/dev/null; then
            err "sshd 配置校验失败，已回滚"
            snap_restore_last || true
            return 1
        fi
        ok "sshd 配置校验通过"
    fi

    if have systemctl; then
        run systemctl enable --now ssh 2>/dev/null || run systemctl enable --now sshd 2>/dev/null || \
            warn "启动 ssh 服务失败，检查 systemctl status ssh"
        run systemctl reload ssh 2>/dev/null || run systemctl reload sshd 2>/dev/null || \
            run systemctl restart ssh 2>/dev/null || true
        ok "SSH 服务已重载"
    fi
    note "现在 root 只能凭密钥登录；密钥没配好之前别断开当前会话"
}

snap_restore_last() {
    [[ -d $BACKUP_ROOT ]] || return 1
    local last
    last=$(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort | tail -1)
    [[ -n $last && -f "$last/manifest" ]] || return 1
    local src base
    while IFS=$'\t' read -r src base; do
        [[ -n ${src:-} ]] || continue
        cp -a "$last/$base" "$src" 2>/dev/null && ok "已回滚 $src"
    done <"$last/manifest"
}

set_root_password() {
    need_root || return 1
    section "设置 root 密码"
    note "推荐留空以保持 root 密码锁定（Kali 默认）；如需启用会提示"
    local p1 p2
    p1=$(ask_secret "新 root 密码（留空取消）")
    [[ -z $p1 ]] && { info "已取消"; return 0; }
    if (( ${#p1} < 12 )); then
        warn "长度 < 12，弱口令在公网机器上等于直接送"
        confirm "仍然使用?" || return 1
    fi
    p2=$(ask_secret "再输一遍")
    [[ "$p1" == "$p2" ]] || { err "两次不一致"; return 1; }
    if run_sh "printf 'root:%s' $(printf '%q' "$p1") | chpasswd"; then
        ok "root 密码已更新"
        run_sh "passwd -u root >/dev/null 2>&1 || true"
    else
        err "设置失败"
        return 1
    fi
}

set_dns() {
    need_root || return 1
    section "DNS 配置"
    printf '  1) 阿里 223.5.5.5 / 223.6.6.6\n' >&2
    printf '  2) 腾讯 119.29.29.29 / 182.254.116.116\n' >&2
    printf '  3) 百度 180.76.76.76\n' >&2
    printf '  4) Cloudflare 1.1.1.1 / 1.0.0.1\n' >&2
    printf '  5) Google 8.8.8.8 / 8.8.4.4\n' >&2
    local c servers
    c=$(ask "选择" "1")
    case "$c" in
        1) servers="223.5.5.5 223.6.6.6" ;;
        2) servers="119.29.29.29 182.254.116.116" ;;
        3) servers="180.76.76.76" ;;
        4) servers="1.1.1.1 1.0.0.1" ;;
        5) servers="8.8.8.8 8.8.4.4" ;;
        *) return 0 ;;
    esac

    local rc=/etc/resolv.conf
    if [[ -L $rc ]]; then
        warn "$rc 是软链接（systemd-resolved 接管中），直接改会被覆盖"
        if confirm "改为实体文件？(会断开 resolved 的自管理)"; then
            snap_file "$rc" || true
            run rm -f "$rc"
        else
            info "改用 resolved 配置"
            local rf=/etc/systemd/resolved.conf.d/99-leclite.conf
            snap_file "$rf" || true
            mkdir -p "$(dirname "$rf")" 2>/dev/null || true
            local dh=""
            for s in $servers; do dh+=" $s"; done
            run_sh "printf '[Resolve]\nDNS=%s\n' $(printf '%q' "$dh") > $rf"
            run systemctl restart systemd-resolved 2>/dev/null || warn "重启 resolved 失败"
            ok "已通过 systemd-resolved 设置 DNS:$dh"
            return 0
        fi
    fi

    snap_file "$rc" || true
    local content=""
    for s in $servers; do content+="nameserver $s"$'\n'; done
    if run_sh "printf '%s' $(printf '%q' "$content") > $rc"; then
        ok "已写入 $rc"
        describe_dns
    else
        err "写入失败"
        return 1
    fi
}

describe_dns() {
    if have getent; then
        if getent hosts github.com >/dev/null 2>&1; then
            ok "解析验证通过 (github.com)"
        else
            warn "解析验证失败，检查网络/上游"
        fi
    fi
}

base_menu() {
    while true; do
        section "基础配置"
        printf '  1) SSH 加固（root 仅密钥、写入 drop-in、语法校验）\n' >&2
        printf '  2) 设置 root 密码\n' >&2
        printf '  3) 设置 DNS\n' >&2
        printf '  4) 显示网络接口\n' >&2
        printf '  0) 返回\n' >&2
        case "$(ask "选择" "0")" in
            1) set_ssh_safe; pause ;;
            2) set_root_password; pause ;;
            3) set_dns; pause ;;
            4) ip -brief addr 2>/dev/null || ifconfig -a 2>/dev/null || warn "无 ip/ifconfig"; pause ;;
            *) return 0 ;;
        esac
    done
}

# ────────────────────────────────────────────────────────────────
# 工具链
# ────────────────────────────────────────────────────────────────

APT_CORE=(curl wget git jq unzip zip tar vim tmux htop net-tools dnsutils whois ca-certificates)
APT_SEC=(nmap netcat-openbsd tcpdump python3 python3-pip python3-venv pipx)
APT_OPT=(masscan sqlmap ffuf gobuster whatweb nikto hydra john)

apt_install_group() {
    local label="$1"; shift
    local pkg avail=() missing=()
    info "$label"
    for pkg in "$@"; do
        if dpkg -s "$pkg" >/dev/null 2>&1; then
            continue
        fi
        if apt-cache show "$pkg" >/dev/null 2>&1; then
            avail+=("$pkg")
        else
            missing+=("$pkg")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        warn "当前源里没有: ${missing[*]}"
    fi
    if (( ${#avail[@]} == 0 )); then
        ok "$label 已齐备"
        return 0
    fi
    note "将安装: ${avail[*]}"
    if run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${avail[@]}"; then
        ok "$label 安装完成"
        return 0
    fi
    err "$label 安装失败"
    return 1
}

install_go_tools() {
    need_root || return 1
    section "Go 工具（httpx/subfinder/nuclei）"
    if ! have go; then
        info "先装 golang-go"
        run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq golang-go || {
            err "安装 golang-go 失败"; return 1; }
    fi
    local tools=(httpx subfinder nuclei) t
    for t in "${tools[@]}"; do
        info "go install $t@latest"
        if run env GOPROXY=https://goproxy.cn,direct GOBIN=/usr/local/bin \
            go install "github.com/projectdiscovery/$t/cmd/$t@latest"; then
            ok "$t -> /usr/local/bin/$t"
        else
            warn "$t 安装失败（网络或版本问题），可稍后手动重试"
        fi
    done
}

cmd_tools() {
    need_root || return 1
    section "工具链"
    info "刷新包索引"
    run env DEBIAN_FRONTEND=noninteractive apt-get update -qq || warn "apt update 失败，继续尝试安装"

    apt_install_group "基础工具" "${APT_CORE[@]}" || true
    apt_install_group "网络与安全工具" "${APT_SEC[@]}" || true
    if confirm "再装一批可选的渗透工具（masscan/sqlmap/ffuf/gobuster/whatweb/nikto/hydra/john）?"; then
        apt_install_group "可选工具" "${APT_OPT[@]}" || true
    fi
    if confirm "安装 Go 版 httpx/subfinder/nuclei（走 goproxy.cn）?"; then
        install_go_tools
    fi
    page_break
    cmd_info
}

# ────────────────────────────────────────────────────────────────
# Docker
# ────────────────────────────────────────────────────────────────

docker_mirror_menu() {
    need_root || return 1
    section "Docker 镜像加速"
    local daemon=/etc/docker/daemon.json
    snap_file "$daemon" || true
    mkdir -p /etc/docker 2>/dev/null || true

    local mirrors=(
        "https://docker.1ms.run"
        "https://docker.xuanyuan.me"
        "https://hub-mirror.c.163.com"
    )
    local list="" m
    for m in "${mirrors[@]}"; do list+="\"$m\","; done
    list="${list%,}"

    # 合并已有配置而不是覆盖
    if [[ -f $daemon ]] && have python3; then
        info "合并到已有 daemon.json"
        if run python3 -c "
import json,sys
p='$daemon'
try:
    d=json.load(open(p))
except Exception:
    d={}
d['registry-mirrors']=[${list}]
json.dump(d,open(p,'w'),indent=2)
print('ok')
" >/dev/null; then
            ok "已合并 registry-mirrors"
        else
            warn "合并失败，跳过"
            return 1
        fi
    else
        run_sh "printf '{\n  \"registry-mirrors\": [%s]\n}\n' $(printf '%q' "$list") > $daemon" || {
            err "写入失败"; return 1; }
        ok "已写入 $daemon"
    fi

    if have systemctl; then
        run systemctl daemon-reload 2>/dev/null || true
        run systemctl restart docker 2>/dev/null || warn "重启 docker 失败（可能还没装）"
    fi
    note "验证: docker info | grep -A3 'Registry Mirrors'"
}

install_docker() {
    need_root || return 1
    require_supported_os || return 1
    section "安装 Docker CE（官方源 + signed-by）"

    if have docker; then
        ok "docker 已存在: $(docker --version 2>/dev/null)"
        confirm "仍然重装/更新?" || return 0
    fi

    run apt-get update -qq || warn "apt update 失败"
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        ca-certificates curl gnupg || { err "前置依赖安装失败"; return 1; }

    local keyring=/etc/apt/keyrings/docker.asc
    run install -m 0755 -d /etc/apt/keyrings || return 1
    local base="${MIRROR_BASE[tsinghua]}"
    local distro="$OS_ID"
    [[ $distro == kali ]] && distro=debian  # Kali 用 Debian 的 docker 源

    info "取 GPG key（$base）"
    if ! run curl -fsSL -m 30 -o "$keyring" "$base/docker-ce/linux/$distro/gpg"; then
        warn "清华镜像取 key 失败，回退官方源"
        if ! run curl -fsSL -m 30 -o "$keyring" \
            "https://download.docker.com/linux/$distro/gpg"; then
            err "GPG key 获取失败，检查网络"
            return 1
        fi
    fi
    run chmod a+r "$keyring" || true
    if have gpg; then
        # 记录指纹，便于审计（不硬编码，只打印）
        info "key 指纹: $(gpg --show-keys --with-fingerprint --with-colons "$keyring" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')"
    fi

    local list=/etc/apt/sources.list.d/docker.list
    snap_file "$list" || true
    local line
    line="deb [arch=$(arch) signed-by=$keyring] $base/docker-ce/linux/$distro ${OS_CODENAME} stable"
    if ! run_sh "printf '%s\n' $(printf '%q' "$line") > $list"; then
        err "写入 $list 失败"
        return 1
    fi
    ok "已写入: $line"

    run env DEBIAN_FRONTEND=noninteractive apt-get update -qq || warn "apt update 失败"
    if run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        ok "Docker 安装完成"
    else
        err "Docker 安装失败（源里没有匹配 codename 的包？检查 $list）"
        return 1
    fi

    have systemctl && { run systemctl enable --now docker 2>/dev/null || true; }
    if confirm "配置国内镜像加速?"; then
        docker_mirror_menu
    fi
}

docker_menu() {
    while true; do
        section "Docker"
        local st="未安装"
        have docker && st=$(docker --version 2>/dev/null)
        printf '  当前: %s%s%s\n' "$C_C" "$st" "$C_0" >&2
        printf '  1) 安装/更新 Docker CE\n' >&2
        printf '  2) 配置镜像加速\n' >&2
        printf '  3) 查看状态\n' >&2
        printf '  0) 返回\n' >&2
        case "$(ask "选择" "0")" in
            1) install_docker; pause ;;
            2) docker_mirror_menu; pause ;;
            3) docker info 2>/dev/null | head -30 || warn "docker 未就绪"; pause ;;
            *) return 0 ;;
        esac
    done
}

# ────────────────────────────────────────────────────────────────
# 靶场（本地绑定 + 随机口令 + .env 0600）
# ────────────────────────────────────────────────────────────────

# 项目名只允许字母数字-_，防止 "lec lab → 删项目" 输入 ../../etc 变成 rm -rf /etc
lab_dir() {
    local name="${1:-}"
    if [[ -z $name || ! $name =~ ^[a-zA-Z0-9_-]+$ ]]; then
        err "项目名非法（只允许字母数字 - _）：'${name}'"
        return 1
    fi
    printf '%s/%s' "$LAB_ROOT" "$name"
}

lab_bind() {
    if (( PUBLIC_BIND )); then
        printf '0.0.0.0'
    else
        printf '127.0.0.1'
    fi
}

ensure_docker() {
    have docker || { err "先安装 Docker（菜单 5）"; return 1; }
    docker info >/dev/null 2>&1 || { err "Docker 守护进程没起来：systemctl start docker"; return 1; }
}

compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    elif have docker-compose; then
        docker-compose "$@"
    else
        err "缺少 compose 插件"
        return 1
    fi
}

deploy_vulfocus() {
    need_root || return 1
    ensure_docker || return 1
    section "部署 Vulfocus 漏洞靶场"
    local bind port name=vulfocus
    bind=$(lab_bind)
    port=$(ask "Web 端口" "8080")

    if (( PUBLIC_BIND )); then
        warn "将监听 0.0.0.0:$port —— 公网可访问，靶场本身有 RCE，确认这是隔离环境"
        confirm "真的要对公网开放?" || return 1
    fi

    if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
        warn "容器 $name 已存在"
        if confirm "删除并重建?"; then
            run docker rm -f "$name" >/dev/null 2>&1 || true
        else
            return 0
        fi
    fi

    local durl
    durl="$bind:$port:80"
    if run docker run -d --name "$name" --restart unless-stopped \
        -p "$durl" -e VUL_IP="$(best_ip)" vulfocus/vulfocus:latest; then
        sleep 3
        ok "已启动"
        note "访问: http://${bind}:${port}"
        note "上游镜像默认 admin/admin，登录后会被强制改密；需要随机口令用 lec pass"
        if [[ $bind == 127.0.0.1 ]]; then
            note "远程访问请走 SSH 隧道: ssh -L ${port}:127.0.0.1:${port} user@host"
        fi
    else
        err "启动失败，看日志: docker logs $name"
        return 1
    fi
}

deploy_hfish() {
    need_root || return 1
    ensure_docker || return 1
    section "部署 HFish 蜜罐"
    local dir bind web sshp
    dir=$(lab_dir hfish) || return 1
    bind=$(lab_bind)
    web=$(ask "Web 端口" "4433")
    sshp=$(ask "SSH 蜜罐端口" "2222")

    if (( PUBLIC_BIND )); then
        warn "蜜罐设计上就是给攻击者打的，公网暴露=自愿当靶子"
        confirm "仍要 0.0.0.0 监听?" || return 1
    fi

    run mkdir -p "$dir/data" || return 1
    local body
    body="# managed by leclite
services:
  hfish:
    image: imdevops/hfish:latest
    container_name: hfish
    restart: unless-stopped
    ports:
      - \"${bind}:${web}:4433\"
      - \"${bind}:${sshp}:22\"
    volumes:
      - ./data:/opt/hfish/data
"
    if ! run_sh "printf '%s' $(printf '%q' "$body") > $dir/docker-compose.yml"; then
        err "写 compose 文件失败"
        return 1
    fi
    ok "compose 已生成: $dir/docker-compose.yml"

    if ( cd "$dir" && compose up -d ); then
        ok "HFish 已启动"
        note "访问 http://${bind}:${web} ，首次进入网页初始化管理员账号（无默认口令）"
    else
        err "启动失败，看: cd $dir && docker compose logs"
        return 1
    fi
}

# 拉远端文件；直连失败自动走 gh-proxy 镜像
fetch_url() {
    local url="$1" out="$2"
    if (( DRY_RUN )); then
        printf '  %s[dry-run]%s curl -o %s %s\n' "$C_Y" "$C_0" "$out" "$url" >&2
        return 0
    fi
    if curl -fsSL -m 60 -o "$out" "$url" 2>/dev/null; then
        _log "FETCH ok $url"
        return 0
    fi
    warn "直连失败，尝试 gh-proxy 镜像"
    if curl -fsSL -m 90 -o "$out" "https://gh-proxy.com/${url}" 2>/dev/null; then
        _log "FETCH proxy ok $url"
        return 0
    fi
    rm -f "$out" 2>/dev/null
    _log "FETCH fail $url"
    return 1
}

# 把 compose 里的裸端口映射收窄到 127.0.0.1
#   - "5003:443"      -> - "127.0.0.1:5003:443"
#   - - 5003:443      -> - "127.0.0.1:5003:443"
#   - "0.0.0.0:80:80" -> - "127.0.0.1:80:80"
narrow_compose_ports() {
    local file="$1" bind="$2"
    (( DRY_RUN )) && { printf '  %s[dry-run]%s 收窄端口 -> %s\n' "$C_Y" "$C_0" "$bind" >&2; return 0; }
    sed -i -E \
        -e "s/^([[:space:]]*-[[:space:]]*)\"?0\.0\.0\.0:([0-9]+):([0-9]+)\"?/\1\"${bind}:\2:\3\"/" \
        -e "s/^([[:space:]]*-[[:space:]]*)\"?([0-9]+):([0-9]+)\"?[[:space:]]*$/\1\"${bind}:\2:\3\"/" \
        "$file"
}

# 官方 compose 部署：拉取 -> 展示 -> 收窄端口 -> 扫口令 -> 语法校验 -> 起
# 不内置硬编码 compose 模板，避免上游字段变更后脚本静默失效
deploy_official_compose() {
    local name="$1" compose_url="$2" upstream="$3"
    need_root || return 1
    ensure_docker || return 1
    section "部署 $name（官方 compose）"

    local dir bind
    dir=$(lab_dir "$name") || return 1
    bind=$(lab_bind)
    if [[ -d $dir ]]; then
        warn "$dir 已存在"
        confirm "删除并重新部署?" || return 0
        ( cd "$dir" && compose down -v 2>/dev/null ) || true
        run rm -rf "$dir"
    fi
    run mkdir -p "$dir" || return 1

    info "来源: $compose_url"
    if ! fetch_url "$compose_url" "$dir/docker-compose.yml"; then
        err "拉取官方 compose 失败（网络受限？可手动下载后放到 $dir/docker-compose.yml 再重试）"
        note "上游仓库: $upstream"
        return 1
    fi

    section "审计 compose（前 40 行）"
    sed -n '1,40p' "$dir/docker-compose.yml" | sed 's/^/    /' >&2

    if (( PUBLIC_BIND )); then
        warn "保持上游端口映射，将暴露到 0.0.0.0"
        confirm "确认这是隔离环境?" || return 1
    else
        narrow_compose_ports "$dir/docker-compose.yml" "$bind"
        ok "端口映射已收窄到 $bind"
    fi

    # 不替上游改口令，但把发现的硬编码口令摊开给用户看
    local hits
    hits=$(grep -niE '(password|passwd|secret|token|admin_pass)' "$dir/docker-compose.yml" 2>/dev/null | head -20)
    if [[ -n $hits ]]; then
        warn "compose 里存在口令类字段（脚本不会擅自修改上游字段）:"
        printf '%s\n' "$hits" | sed 's/^/    /' >&2
        note "部署后请立刻登录改掉，或先改 $dir/docker-compose.yml 再起"
    else
        ok "未发现硬编码口令"
    fi

    if ! ( cd "$dir" && compose config -q 2>/dev/null ); then
        err "compose 语法/引用校验失败，未启动"
        note "看: cd $dir && docker compose config"
        return 1
    fi
    ok "compose 校验通过"

    if ( cd "$dir" && compose up -d ); then
        ok "$name 已启动（$dir）"
        ( cd "$dir" && compose ps 2>/dev/null | sed 's/^/    /' ) >&2 || true
    else
        err "启动失败，看: cd $dir && docker compose logs --tail=50"
        return 1
    fi
}

lab_audit() {
    local name
    name=$(ask "要审计的项目名" "")
    [[ -z $name ]] && return 1
    local dir f
    dir=$(lab_dir "$name") || return 1
    f="$dir/docker-compose.yml"
    [[ -f $f ]] || { err "找不到 $f"; return 1; }
    section "审计 $name"
    printf '  %s端口映射%s\n' "$C_W" "$C_0" >&2
    grep -nE '^[[:space:]]*-[[:space:]]*"?[0-9.:]+:[0-9]+' "$f" | sed 's/^/    /' >&2 || note "无端口映射"
    printf '\n  %s敏感字段%s\n' "$C_W" "$C_0" >&2
    grep -niE '(password|passwd|secret|token|key)' "$f" | sed 's/^/    /' >&2 || note "无"
    printf '\n  %s绑定地址%s\n' "$C_W" "$C_0" >&2
    if grep -qE '127\.0\.0\.1' "$f"; then
        ok "已限制在本机"
    else
        warn "存在对外监听，确认这是隔离环境"
    fi
}

deploy_compose_url() {
    need_root || return 1
    ensure_docker || return 1
    section "部署自定义 compose"
    local url name dir
    url=$(ask "docker-compose.yml 的 URL（或本地路径）" "")
    [[ -z $url ]] && return 1
    name=$(ask "项目名(英文)" "lab")
    [[ $name =~ ^[a-zA-Z0-9_-]+$ ]] || { err "项目名只能含字母数字-_"; return 1; }
    dir=$(lab_dir "$name") || return 1
    run mkdir -p "$dir" || return 1

    if [[ $url =~ ^https?:// ]]; then
        info "下载 $url"
        run curl -fsSL -m 60 -o "$dir/docker-compose.yml" "$url" || { err "下载失败"; return 1; }
    else
        run cp -a "$url" "$dir/docker-compose.yml" || { err "复制失败"; return 1; }
    fi
    snap_file "$dir/docker-compose.yml" || true
    note "外部 compose 未做审计，起之前自己看一眼内容"
    if ( cd "$dir" && compose up -d ); then
        ok "已部署到 $dir"
    else
        err "启动失败"
        return 1
    fi
}

lab_list() {
    [[ -d $LAB_ROOT ]] || { note "还没有部署过靶场"; return 0; }
    local d
    for d in "$LAB_ROOT"/*/; do
        [[ -f "$d/docker-compose.yml" ]] || continue
        printf '  %s%s%s\n' "$C_C" "$(basename "$d")" "$C_0" >&2
        ( cd "$d" && compose ps 2>/dev/null | sed 's/^/    /' ) >&2 || true
    done
}

lab_stop() {
    local name
    name=$(ask "要停止的项目名(hfish/lab...)" "")
    [[ -z $name ]] && return 1
    local dir
    dir=$(lab_dir "$name") || return 1
    [[ -f "$dir/docker-compose.yml" ]] || { err "找不到 $dir"; return 1; }
    ( cd "$dir" && compose down ) && ok "已停止 $name"
}

lab_remove() {
    local name
    name=$(ask "要删除的项目名" "")
    [[ -z $name ]] && return 1
    local dir
    dir=$(lab_dir "$name") || return 1
    [[ -d $dir ]] || { err "找不到 $dir"; return 1; }
    confirm "删除 $dir（含容器与数据）?" || return 1
    ( cd "$dir" && compose down -v 2>/dev/null ) || true
    run rm -rf "$dir" && ok "已删除 $name"
}

lab_menu() {
    while true; do
        section "靶场与工具部署"
        printf '  绑定地址: %s%s%s  (--public 可改为 0.0.0.0)\n' \
            "$C_C" "$(lab_bind)" "$C_0" >&2
        printf '  1) Vulfocus 漏洞靶场\n' >&2
        printf '  2) HFish 蜜罐\n' >&2
        printf '  3) ARL 资产侦察灯塔（官方 compose + 审计 + 收窄端口）\n' >&2
        printf '  4) Viper 图形化红队平台（官方 compose + 审计 + 收窄端口）\n' >&2
        printf '  5) 自定义 compose（URL/本地文件）\n' >&2
        printf '  6) 列出已部署\n' >&2
        printf '  7) 审计已部署 compose（端口/口令/监听面）\n' >&2
        printf '  8) 停止某项目\n' >&2
        printf '  9) 删除某项目\n' >&2
        printf '  0) 返回\n' >&2
        case "$(ask "选择" "0")" in
            1) deploy_vulfocus; pause ;;
            2) deploy_hfish; pause ;;
            3) deploy_official_compose "arl" \
                   "https://raw.githubusercontent.com/TophantTechnology/ARL/master/docker-compose.yml" \
                   "https://github.com/TophantTechnology/ARL"
               pause ;;
            4) deploy_official_compose "viper" \
                   "https://raw.githubusercontent.com/FunnyWolf/Viper/master/docker-compose.yml" \
                   "https://github.com/FunnyWolf/Viper"
               pause ;;
            5) deploy_compose_url; pause ;;
            6) lab_list; pause ;;
            7) lab_audit; pause ;;
            8) lab_stop; pause ;;
            9) lab_remove; pause ;;
            *) return 0 ;;
        esac
    done
}

# ────────────────────────────────────────────────────────────────
# 深度自检 doctor
# ────────────────────────────────────────────────────────────────

DOC_PASS=0
DOC_WARN=0
DOC_FAIL=0

dg_ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*" >&2; DOC_PASS=$((DOC_PASS + 1)); }
dg_warn() { printf '  %s⚠%s %s\n' "$C_Y" "$C_0" "$*" >&2; DOC_WARN=$((DOC_WARN + 1)); }
dg_fail() { printf '  %s✘%s %s\n' "$C_R" "$C_0" "$*" >&2; DOC_FAIL=$((DOC_FAIL + 1)); }

cmd_doctor() {
    DOC_PASS=0; DOC_WARN=0; DOC_FAIL=0
    title "深度自检 doctor"

    # 平台
    if detect_os; then
        dg_ok "系统 $OS_NAME ($OS_ID $OS_VER / ${OS_CODENAME:-n/a})"
    else
        dg_fail "不支持的系统: $OS_NAME"
    fi
    local a
    a=$(arch)
    case "$a" in
        x86_64|amd64|aarch64|arm64) dg_ok "架构 $a" ;;
        *) dg_warn "架构 $a（部分官方镜像无对应二进制）" ;;
    esac

    # 资源
    local mem free_gb
    mem=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    if [[ -n ${mem:-} ]]; then
        if (( mem < 1024 )); then
            dg_warn "内存 ${mem}MB < 1G，跑 Docker 靶场会吃紧"
        else
            dg_ok "内存 ${mem}MB"
        fi
    else
        dg_warn "读不到内存信息"
    fi
    free_gb=$(df -BG / 2>/dev/null | awk 'NR==2{gsub(/G/,"",$4); print $4}')
    if [[ -n ${free_gb:-} && $free_gb =~ ^[0-9]+$ ]]; then
        if (( free_gb < 10 )); then
            dg_warn "根分区剩余 ${free_gb}G < 10G（镜像容易塞满）"
        else
            dg_ok "根分区剩余 ${free_gb}G"
        fi
    fi

    # 依赖
    local c
    for c in curl wget git jq unzip gpg ss; do
        if have "$c"; then
            dg_ok "依赖 $c"
        else
            dg_warn "缺 $c（部分功能受限）"
        fi
    done

    # init 系统
    if have systemctl && [[ -d /run/systemd/system ]]; then
        dg_ok "systemd 运行中"
    else
        dg_warn "无 systemd（容器内？服务管理会失效）"
    fi

    # DNS
    if getent hosts github.com >/dev/null 2>&1; then
        dg_ok "DNS 解析正常（github.com）"
    else
        dg_fail "DNS 解析失败"
    fi

    # 镜像连通
    local name lat
    for name in aliyun tsinghua; do
        lat=$(mirror_latency "${MIRROR_BASE[$name]}")
        if [[ $lat == 99 ]]; then
            dg_warn "镜像 $name 不可达"
        else
            dg_ok "镜像 $name 可达 (${lat}s)"
        fi
    done

    # APT 源形态
    local nd=0 f
    for f in /etc/apt/sources.list.d/*.sources; do
        [[ -f $f ]] && nd=$((nd + 1))
    done
    if (( nd > 0 )); then
        dg_ok "APT 使用 deb822 源（$nd 个 .sources）"
    elif [[ -s /etc/apt/sources.list ]]; then
        dg_ok "APT 使用 sources.list"
    else
        dg_warn "没找到有效的 APT 源配置"
    fi

    # SSH
    if have sshd; then
        if sshd -t 2>/dev/null; then
            dg_ok "sshd 配置语法正确"
        else
            dg_fail "sshd 配置语法错误（reload 会失败）"
        fi
        local prl pwa
        prl=$(sshd -T 2>/dev/null | awk '/^permitrootlogin/{print $2}')
        case "${prl:-unknown}" in
            yes) dg_warn "PermitRootLogin=yes（建议 prohibit-password）" ;;
            prohibit-password|without-password) dg_ok "PermitRootLogin=$prl" ;;
            *) dg_warn "PermitRootLogin=${prl:-unknown}" ;;
        esac
        pwa=$(sshd -T 2>/dev/null | awk '/^passwordauthentication/{print $2}')
        if [[ ${pwa:-} == yes ]]; then
            dg_warn "SSH 允许密码登录（公网机器建议只留密钥）"
        else
            dg_ok "SSH 密码登录已关闭"
        fi
    else
        dg_warn "未安装 openssh-server"
    fi

    # root 账号状态
    local rl
    rl=$(passwd -S root 2>/dev/null | awk '{print $2}')
    case "${rl:-}" in
        L) dg_ok "root 密码已锁定" ;;
        P) dg_warn "root 密码可用" ;;
        *) dg_warn "root 密码状态未知" ;;
    esac

    # Docker
    if have docker; then
        if docker info >/dev/null 2>&1; then
            dg_ok "Docker 运行中: $(docker --version 2>/dev/null | cut -d, -f1)"
            if docker compose version >/dev/null 2>&1; then
                dg_ok "compose 插件可用"
            elif have docker-compose; then
                dg_ok "docker-compose v1 可用"
            else
                dg_warn "缺 compose"
            fi
            if docker info 2>/dev/null | grep -qi 'registry mirrors'; then
                dg_ok "已配置镜像加速"
            else
                dg_warn "未配置镜像加速（拉镜像会很慢）"
            fi
        else
            dg_fail "Docker 已安装但守护进程未运行"
        fi
    else
        dg_warn "未安装 Docker（菜单 5 可装）"
    fi

    # 53 端口
    if have ss && ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE ':53$'; then
        dg_warn "53 端口被占用（dnsmasq / systemd-resolved？）"
    else
        dg_ok "53 端口空闲"
    fi

    # 时区
    local tz
    tz=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || true)
    dg_ok "时区 ${tz:-unknown}"

    # 快照与日志
    if [[ -d $BACKUP_ROOT ]]; then
        dg_ok "快照目录 $BACKUP_ROOT（$(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l) 个）"
    else
        dg_warn "还没有任何快照"
    fi
    if [[ -d $LOG_DIR ]]; then
        dg_ok "日志目录 $LOG_DIR"
    else
        dg_warn "日志目录未创建（--debug 时生成）"
    fi

    hr
    printf '  %s✔ %d%s   %s⚠ %d%s   %s✘ %d%s\n' \
        "$C_G" "$DOC_PASS" "$C_0" "$C_Y" "$DOC_WARN" "$C_0" "$C_R" "$DOC_FAIL" "$C_0" >&2

    if (( DOC_FAIL > 0 )); then
        err "有 $DOC_FAIL 项致命问题，先修再部署"
        return 1
    fi
    if (( DOC_WARN > 0 )); then
        warn "$DOC_WARN 项告警，不阻塞但建议处理"
    else
        ok "全部通过"
    fi
    return 0
}

# ────────────────────────────────────────────────────────────────
# 备份 / 卸载 / 更新检查
# ────────────────────────────────────────────────────────────────

# 生成随机强口令。不落盘、不进日志，只打印一次。
cmd_pass() {
    local len="${1:-24}" p
    if [[ ! $len =~ ^[0-9]+$ ]]; then
        err "长度必须是数字，例如: lec pass 32"
        return 1
    fi
    if (( len < 12 )); then
        warn "长度 ${len} < 12，建议 16 以上"
    fi
    p=$(gen_pass "$len")
    printf '\n  %s%s%s\n\n' "$C_BG" "$p" "$C_0" >&2
    note "来源 /dev/urandom，不写文件、不写日志；复制走自己存好"
}

cmd_backup() {
    case "${1:-list}" in
        list)    section "快照列表"; snap_list ;;
        restore) snap_restore ;;
        *)       err "用法: lec backup [list|restore]" ;;
    esac
}

cmd_uninstall() {
    need_root || return 1
    section "卸载 $APP"
    note "会删除: $BIN_PATH, $APP_HOME"
    note "会保留: $BACKUP_ROOT（快照）, $LOG_DIR（日志）"
    confirm "确认卸载?" || return 0
    run rm -f "$BIN_PATH"
    run rm -rf "$APP_HOME"
    ok "已卸载。快照仍在 $BACKUP_ROOT，可用 lec backup restore 手动回滚"
}

check_update() {
    section "更新检查（只提示，不自动改自己）"
    local repo="${LECLITE_REPO:-}"
    if [[ -z $repo ]]; then
        note "未配置 LECLITE_REPO，跳过"
        return 0
    fi
    have git || { warn "缺 git"; return 1; }
    local remote
    remote=$(git -c safe.directory="$APP_HOME" ls-remote "$repo" HEAD 2>/dev/null | cut -f1)
    if [[ -z $remote ]]; then
        warn "无法连接远端仓库"
        return 1
    fi
    printf '  本地版本: %s\n  远端 HEAD: %s\n' "$VERSION" "${remote:0:7}" >&2
    note "升级方式: cd $APP_HOME && git pull —— 本脚本不会自己替换自己"
}

# ────────────────────────────────────────────────────────────────
# 主菜单
# ────────────────────────────────────────────────────────────────

main_menu() {
    while true; do
        title "$APP v$VERSION   Linux 安全环境配置器"
        printf '  1) 系统自检与信息\n' >&2
        printf '  2) APT 换源（deb822 兼容 / 测速 / 快照回滚）\n' >&2
        printf '  3) 基础配置（SSH / root / DNS）\n' >&2
        printf '  4) 工具链安装\n' >&2
        printf '  5) Docker\n' >&2
        printf '  6) 靶场部署（默认只听 127.0.0.1）\n' >&2
        printf '  7) 备份与回滚\n' >&2
        printf '  8) 深度自检 doctor\n' >&2
        printf '  9) 检查更新\n' >&2
        printf ' 10) 卸载\n' >&2
        printf '  q) 退出\n' >&2
        hr
        case "$(ask "选择" "q")" in
            1) cmd_info; pause ;;
            2) cmd_apt ""; pause ;;
            3) base_menu ;;
            4) cmd_tools; pause ;;
            5) docker_menu ;;
            6) lab_menu ;;
            7) cmd_backup list; if confirm "现在恢复某个快照?"; then snap_restore; fi; pause ;;
            8) cmd_doctor; pause ;;
            9) check_update; pause ;;
            10) cmd_uninstall; exit 0 ;;
            q|Q) exit 0 ;;
            *) warn "无效选项" ;;
        esac
    done
}

usage() {
    cat <<EOF
$APP v$VERSION — 轻量 Linux 安全环境配置器

用法:
  $APP                 交互菜单（需 root 才能执行改动）
  $APP info            系统自检
  $APP doctor          深度自检：平台/资源/依赖/DNS/镜像/SSH/Docker/端口
  $APP apt auto        自动测速换源（aliyun|tencent|huawei|tsinghua|ustc|official|restore）
  $APP tools           安装基础/安全工具链
  $APP docker          安装 Docker CE + 镜像加速
  $APP lab             靶场菜单（vulfocus / hfish / ARL / Viper / 自定义）
  $APP backup list     列出系统更改快照
  $APP backup restore  从快照回滚
  $APP pass [长度]     生成随机强口令（默认 24 位，不落盘）
  $APP --check-update  只检查更新，不自我替换
  $APP --uninstall     卸载

选项:
  --dry-run   只打印将要执行的命令，不落地
  --yes       跳过所有确认（脚本化时用）
  --debug     把命令与错误写入 $LOG_DIR
  --public    靶场绑定 0.0.0.0（默认 127.0.0.1，会二次确认）

安全设计:
  · 从不自更新：不会从网络覆盖自身代码
  · 脚本内无任何默认口令：需要口令时用 lec pass 生成，不落盘不记日志
  · 上游镜像自带的默认口令（如 Vulfocus 首次 admin/admin）部署时会明确提示改
  · 写系统文件前必快照：$BACKUP_ROOT
  · 不开 set -e：失败就地降级并记录，不让整个程序消失
EOF
}

parse_args() {
    local -a rest=()
    for arg in "$@"; do
        case "$arg" in
            --dry-run) DRY_RUN=1 ;;
            --yes|-y)  ASSUME_YES=1 ;;
            --debug)   DEBUG=1; mkdir -p "$LOG_DIR" 2>/dev/null || true ;;
            --public)  PUBLIC_BIND=1 ;;
            --check-update) check_update; exit 0 ;;
            --uninstall)    cmd_uninstall; exit 0 ;;
            -h|--help)      usage; exit 0 ;;
            -V|--version)   printf '%s %s\n' "$APP" "$VERSION"; exit 0 ;;
            *) rest+=("$arg") ;;
        esac
    done
    if (( ${#rest[@]} > 0 )); then
        case "${rest[0]}" in
            info)     cmd_info ;;
            doctor)   cmd_doctor ;;
            apt)      cmd_apt "${rest[1]:-}" ;;
            base)     base_menu ;;
            tools)    cmd_tools ;;
            docker)   install_docker ;;
            lab)      lab_menu ;;
            backup)   cmd_backup "${rest[1]:-list}" ;;
            pass)     cmd_pass "${rest[1]:-}" ;;
            help)     usage ;;
            *)        err "未知命令: ${rest[0]}"; usage; exit 1 ;;
        esac
        # 子命令的退出码必须透传，否则脚本化调用永远拿到 0
        exit $?
    fi
}

main() {
    parse_args "$@"
    detect_os || true
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        warn "当前不是 root，改动类操作会要求 sudo"
    fi
    main_menu
}

main "$@"
