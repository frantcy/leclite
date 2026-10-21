# leclite

轻量 Linux 安全环境配置器 —— Ubuntu / Debian / Kali 的换源、基础加固、工具链、Docker 与靶场部署。

一个文件，一个人看得完：`leclite.sh` 约 1600 行，只依赖 bash + coreutils + curl。

```
  1) 系统自检与信息
  2) APT 换源（deb822 兼容 / 测速 / 快照回滚）
  3) 基础配置（SSH / root / DNS）
  4) 工具链安装
  5) Docker
  6) 靶场部署（Vulfocus / HFish / ARL / Viper / 自定义，默认只听 127.0.0.1）
  7) 备份与回滚
  8) 深度自检 doctor
  9) 检查更新
 10) 卸载
```

## 安装

```bash
git clone https://github.com/frantcy/leclite.git
cd leclite
sudo ./install.sh --verify      # 校验 SHA256 后装到 /opt/leclite，注册 lec
```

安装器会做两件容易被忽略的事：

- `/opt/leclite` 归 `root:root` 且 `go-w`（组/其他不可写）。这个目录里的脚本以 root 执行，若可被普通用户改写，任何能写它的人就等于拿到 root。
- `lec` 用 `sudo -- bash ...`，**刻意不带 `-E`**。`sudo -E` 会把调用者环境变量带进 root 进程，`BASH_ENV=/tmp/evil.sh lec` 就能让 root 的 bash source 任意文件——这是一条完整的本地提权链。

本地开发不想装：

```bash
sudo ./install.sh --bin-only    # 命令指向当前目录，改代码立即生效
```

不想装也行，直接跑：

```bash
sudo bash leclite.sh
sudo bash leclite.sh info
```

## 用法

```bash
lec                            # 菜单
lec info                       # 浅自检：OS/内存/磁盘/依赖/最近快照
lec doctor                     # 深度自检：平台/资源/依赖/DNS/镜像/SSH/Docker/端口/时区
lec apt auto                   # 测速选最快镜像并切换
lec apt aliyun                 # 指定镜像：aliyun|tencent|huawei|tsinghua|ustc|official
lec apt restore                # 从快照回滚源配置
lec tools                      # 装基础 + 安全工具链（可选 Go 工具）
lec docker                     # 装 Docker CE + 配镜像加速
lec lab                        # 靶场菜单：vulfocus / hfish / ARL / Viper / 自定义 / 审计
lec backup list                # 列出所有系统更改快照
lec --dry-run apt auto         # 只打印命令，不落地
lec --yes tools                # 无交互（脚本化）
```

`doctor` 的退出码可以直接进流水线：`0` 全通过（可能带告警），`1` 有致命项，`>1` 说明脚本自己崩了。

## 靶场：拉官方 compose，不内置模板

ARL、Viper 这类平台的上游 `docker-compose.yml` 字段会变（服务名、环境变量、镜像 tag 都动过）。把模板抄进脚本，上游一改就静默失效——所以这里做的是**四步流水线**，而不是硬编码 YAML：

1. **拉**：从上游仓库取 `docker-compose.yml`；直连失败自动走 `gh-proxy.com` 镜像
2. **看**：把前 40 行铺给你看，`lec lab` 里还有 `审计` 单独复查端口/口令/监听面
3. **收窄**：`- "5003:443"` → `- "127.0.0.1:5003:443"`（`--public` 才保留上游映射，且二次确认）
4. **校验再起**：`docker compose config -q` 通过才 `up -d`；不改上游口令字段，但把 `password|secret|token` 行全列出来让你自己改

Vulfocus / HFish 走内置配置（参数少、稳定），HFish 采用网页首次初始化，不预设账号。


## 设计取舍

这套东西是照着常见"一键全家桶"的坑反过来写的，四条硬规则：

**1. 从不自更新。**
脚本永远不会从网络下载并覆盖自己。很多同类脚本会在启动时 `git pull` 或拉 tar.gz 覆盖自身目录，等于把"root 执行任意代码"的开关交给了远端仓库。这里升级只有一条路：你自己 `cd /opt/leclite && git pull`。`--check-update` 只对比远端 HEAD 并打印，不动文件。

**2. 没有默认口令。**
不写 `admin/admin`、不写 `password123`、不写 `MYSQL_ROOT_PASSWORD=123456`。需要口令的地方由你决定：`lec pass` 从 `/dev/urandom` 取，默认 24 位字母数字，**不落盘、不写日志**，只在终端打印一次。

```
$ lec pass 32
  K7dQ2mXvR9pLwT4nB8sYcF6hJ3gZaE1u
```

上游镜像自带的默认口令不会替你沿用：Vulfocus 首次登录是 `admin/admin` 且强制改密，部署时会明确打出来；ARL/Viper 的 compose 里若有 `password`/`secret` 字段，会整行列出让你自己改，脚本不擅自改上游字段。HFish 采用网页首次初始化，不预设账号。

**3. 默认只听 127.0.0.1。**
靶场和面板默认 `-p 127.0.0.1:PORT:...`，远程用 SSH 隧道访问。要暴露到公网必须加 `--public`，并且会二次确认——因为靶场本身带 RCE，蜜罐本身欢迎被打。

**4. 写系统文件前必快照。**
`/etc/apt/sources.list`、`sources.list.d/*`、`sshd_config`、`resolv.conf`、`daemon.json` 每次改动前复制到 `/var/backups/leclite/<时间戳>/`，并写 manifest 记录原路径。`lec backup restore` 一键回滚。

## 为什么不开 `set -e`

交互式系统配置脚本里 `set -e` 的危害远大于收益：`apt-get update` 因为一个第三方源 404 返回非零，整个程序直接消失，用户看到的是"脚本闪退"，而不是"源不可用，要不要换一个"。

这里用 `set -uo pipefail` + 显式返回值判断 + `ERR` trap 记现场（`/var/log/leclite/error.log`，含失败命令、文件位置、调用栈），失败就地降级、继续下一次交互。

## SSH 加固为什么写 drop-in

不 `sed` 主配置，而是写 `/etc/ssh/sshd_config.d/99-leclite.conf`：

```
PermitRootLogin prohibit-password
PubkeyAuthentication yes
MaxAuthTries 4
LoginGraceTime 20
X11Forwarding no
```

好处是可整块删除、不会改乱别人的规则。改完先 `sshd -t` 校验，校验不过自动回滚——不会出现"重启 SSH 之后连不上"的经典事故。

`root` 默认是 `prohibit-password`（只允许密钥），不是 `yes`。要开 root 密码登录请自己改，脚本不替你做这个决定。

## APT 换源怎么处理 deb822

Kali 2023+ 与 Ubuntu 24.04 已经改用 `/etc/apt/sources.list.d/*.sources`（deb822 格式），老的"覆写 `/etc/apt/sources.list`"做法会：

- 与 deb822 源并存 → 重复索引、重复告警
- 抹掉 docker/metasploit 等模块自己加的第三方源

这里的做法是二选一：

- 存在 `*.sources` → 只替换 `URIs:` 行里的主机名，**保留 `Suites` / `Components` / `Signed-By`**
- 不存在 → 生成 `sources.list`（按 ubuntu/debian/kali 分别生成，debian 的 security 单独指向 `debian-security`）

## 目录

```
leclite/
├── leclite.sh             主脚本（单文件，约 1600 行）
├── install.sh             安装器（--verify 支持 SHA256 校验）
├── SHA256SUMS             发布校验
├── Makefile               make check = shellcheck + bash -n + smoke
├── .github/workflows/     CI：shellcheck、语法、Ubuntu 24.04 实跑 info/doctor/dry-run
└── tests/smoke.sh         参数解析 + 退出码 + dry-run 不落地的断言
```

## 已验证 / 未验证

诚实说明边界，别把"看起来对"当"跑通"：

**已验证（CI 每次 push 都跑）**

- `shellcheck -S warning` 三个脚本 0 warning
- `bash -n` 语法
- smoke：参数解析、未知命令/未知镜像的退出码、`doctor` 正常退出、dry-run 不改 `sources.list` 与 deb822 源
- 在 `ubuntu-24.04` 上实跑：`info`、`doctor`（连跑两次验证幂等）、`--dry-run apt tsinghua`（覆盖 deb822 URI 替换分支）、`--dry-run tools`
- 远端文件与 `SHA256SUMS` 一致、`CR=0`（无 CRLF 污染）

**未验证（需要真实环境，装完自己跑一遍）**

- Docker CE 真实安装（依赖外网 + 具体 codename 在源里存在）
- Vulfocus / HFish / ARL / Viper 真实拉起（拉镜像耗时、上游 compose 可能变）
- SSH 加固的实际生效（需要能重连的会话；脚本已做 `sshd -t` 失败回滚，但真机才验证得了）
- 换源后 `apt-get update` 的真实成功（CI 里是 dry-run，不落地）

## License

MIT
