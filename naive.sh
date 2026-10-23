#!/bin/bash
# naiveproxy v0.1 · 一键安装脚本
# 平台：Debian 12/13、Ubuntu 22.04/24.04（仅 x86_64）
# 菜单：1 安装 / 2 状态 / 3 日志 / 4 改密码 / 5 卸载（序号锁死）
# 不接受任何命令行参数。规格见 SPEC.md；硬约束见 reports/caddy-fork-facts.md。

set -u
set -o pipefail
set -E

CADDY_URL="https://github.com/klzgrad/forwardproxy/releases/download/v2.11.7-naive/caddy-forwardproxy-naive.tar.xz"
CADDY_SHA256="ac97057c925bb098eb575e7b0cb8bd547d4c5f845b09a3dedfbe34444aa7ae88"
OS_RELEASE=/etc/os-release
STATE_FILE=/etc/caddy/.naive-state
UNIT_FILE=/etc/systemd/system/caddy.service
RENEW_SERVICE=/etc/systemd/system/naive-cert-renew.service
RENEW_TIMER=/etc/systemd/system/naive-cert-renew.timer
INSTALL_DEPS='curl tar xz sha256sum getent useradd install'
MENU_DEPS='bash systemctl ss openssl journalctl tail sed awk grep rm'
readonly CADDY_BIN='/usr/local/bin/caddy'
readonly CADDYFILE='/etc/caddy/Caddyfile'
readonly CERT_DIR='/etc/ssl/naiveproxy'
readonly CERT_FILE="${CERT_DIR}/fullchain.pem"
readonly KEY_FILE="${CERT_DIR}/privkey.pem"
readonly WEB_ROOT='/var/www/naive-camouflage'
readonly DATA_DIR='/var/lib/caddy'
readonly LOG_DIR='/var/log/caddy'
readonly RELOAD_HOOK='/usr/local/bin/naive-cert-reload.sh'

# 供 render_caddyfile 使用的状态量（安装时赋值；也可被 verify.sh 覆盖后渲染）
STATE_VERSION='1'
STATE_DOMAIN=''
STATE_USER=''
STATE_PASS=''
STATE_PROBE=''
STATE_PORT='443'
STATE_CERT="${CERT_FILE}"
STATE_KEY="${KEY_FILE}"

TMP_DIR=''
INSTALLING=0
ACME_INSTALLED=0
NEWLY_ISSUED=0
CREATED_FILES=()
CREATED_DIRS=()
msg() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

gen_secret() {
  local n=${1:-24} s=''
  while :; do
    s=$(openssl rand -base64 48 2>/dev/null | tr -dc 'A-Za-z0-9' | cut -c1-"$n")
    if [[ ${#s} -eq $n && $s =~ ^[A-Za-z0-9]+$ ]]; then
      printf '%s' "$s"
      return 0
    fi
  done
}

pct_encode() {
  local s=$1 out='' c i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
      [A-Za-z0-9._~-]) out+=$c ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

ask_domain() {
  local v=''
  while :; do
    printf '域名（如 example.com）: ' >&2
    IFS= read -r v || return 1
    v=${v//[[:space:]]/}
    if [[ $v =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; then
      printf '%s' "$v"
      return 0
    fi
    err '域名格式不正确，请重输'
  done
}

ask_email() {
  local v='' re
  re='^[A-Za-z0-9_%+-]+(\.[A-Za-z0-9_%+-]+)*@([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$'
  while :; do
    printf '邮箱（用于 ACME 注册）: ' >&2
    IFS= read -r v || return 1
    if [[ $v =~ $re ]]; then
      printf '%s' "$v"
      return 0
    fi
    err '邮箱格式不正确，请重输'
  done
}

ask_user() {
  local v='' default_user; default_user=$(gen_secret 8)
  while :; do
    printf '用户名 [%s]: ' "$default_user" >&2
    IFS= read -r v || return 1
    [[ -z $v ]] && v=$default_user
    if [[ $v =~ ^[A-Za-z0-9]{8}$ ]]; then
      printf '%s' "$v"
      return 0
    fi
    err '用户名须为 8 位大小写字母或数字，请重输'
  done
}

check_dns() {
  local domain=$1 ip='' resolved=''
  ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || true)
  ip=${ip//[[:space:]]/}
  resolved=$(getent hosts "$domain" 2>/dev/null | awk 'NR==1 {print $1}')
  if [[ -z $resolved ]]; then
    err "域名 ${domain} 无法解析"
    return 8
  fi
  if [[ -z $ip || $resolved == "$ip" ]]; then
    return 0
  fi
  err "警告：域名 ${domain} 解析到 ${resolved}，本机公网 IP 为 ${ip:-未知}（CDN 场景可忽略）"
  printf '仍要继续安装？输入 yes 继续: ' >&2
  local ans=''
  IFS= read -r ans || return 1
  [[ $ans == 'yes' ]]
}

preflight() {
  if [[ $(id -u) -ne 0 ]]; then
    err '需要 root 运行'
    exit 3
  fi

  local os_id='' os_ver=''
  if [[ -r $OS_RELEASE ]]; then
    os_id=$(. "$OS_RELEASE" 2>/dev/null; printf '%s' "${ID:-}")
    os_ver=$(. "$OS_RELEASE" 2>/dev/null; printf '%s' "${VERSION_ID:-}")
  fi
  case "${os_id} ${os_ver}" in
    'debian 12' | 'debian 13' | 'ubuntu 22.04' | 'ubuntu 24.04') ;;
    *)
      err "不支持的发行版：${os_id:-unknown} ${os_ver:-}"
      err '仅支持 Debian 12/13、Ubuntu 22.04/24.04'
      exit 2
      ;;
  esac

  local arch
  arch=$(uname -m)
  if [[ $arch != 'x86_64' ]]; then
    err "当前架构 ${arch} 不受支持；预编译产物仅有 linux/amd64，需自行 xcaddy 编译"
    exit 2
  fi

  local mem=''
  mem=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)
  if [[ -z ${mem:-} || ${mem:-0} -lt 524288 ]]; then
    err '内存不足 512MB'
    exit 3
  fi

  local c missing=''
  for c in $MENU_DEPS; do
    command -v "$c" >/dev/null 2>&1 || missing="${missing} ${c}"
  done
  if [[ -n $missing ]]; then
    err "缺少依赖命令:${missing}"
    exit 3
  fi

  # 启动闸门只含 S0-01~05；选 1 后依次执行 S0-08、S0-06、S0-07。
}

ensure_deps() {
  local c pkg missing packages='' log='' stage='' pass; local -a args
  for pass in 1 2; do
    missing=''
    for c in $INSTALL_DEPS $MENU_DEPS; do command -v "$c" >/dev/null 2>&1 || missing+=" $c"; done
    if [[ $pass -eq 2 ]]; then
      [[ -z $stage ]] || { err "依赖补全失败（apt-get $stage）"; tail -n 10 "$log" >&2; }
      rm -f -- "$log"
      if [[ -n $stage || -n $missing ]]; then err "仍缺依赖命令:$missing"; exit 3; fi
    fi
    [[ -n $missing ]] || { [[ -z $packages ]] || msg "本次补装系统依赖包：$packages"; return 0; }
    command -v apt-get >/dev/null 2>&1 || { err "当前系统无 apt-get，请手工安装：$missing"; exit 3; }
    for c in $missing; do
      case $c in
        curl) pkg=curl ;;
        tar) pkg=tar ;;
        xz) pkg=xz-utils ;;
        sha256sum) pkg=coreutils ;;
        getent) pkg=libc-bin ;;
        useradd) pkg=passwd ;;
        install) pkg=coreutils ;;
        systemctl|journalctl) pkg=systemd ;;
        ss) pkg=iproute2 ;;
        tail|rm) pkg=coreutils ;;
        awk) pkg=mawk ;;
        *) pkg=$c ;;
      esac
      [[ " $packages " == *" $pkg "* ]] || packages+="${packages:+ }$pkg"
    done
    log=$(mktemp) || { err "无法创建依赖补全日志；仍缺依赖命令:$missing"; exit 3; }; msg "将安装系统依赖包：$packages" >&2
    apt-get update >"$log" 2>&1 || stage=update
    read -r -a args <<<"$packages"; [[ -n $stage ]] || { apt-get install -y --no-install-recommends "${args[@]}" >"$log" 2>&1 || stage=install; }
  done
}
install_acme() {
  local tmp rc=0 email=${2:-${1:-${EMAIL:-}}} acme="${HOME:-/root}/.acme.sh/acme.sh"
  tmp=$(mktemp -d) || fail_install 5 '安装 acme.sh 失败：无法创建临时目录'
  if ! curl -fL --max-time 120 -o "$tmp/get-acme.sh" https://get.acme.sh ||
    ! sh "$tmp/get-acme.sh" "email=$email" --no-cron; then rc=5; fi
  rm -rf -- "$tmp"
  [[ $rc -eq 0 ]] || fail_install 5 '安装 acme.sh 失败'
  if [[ ! -x $acme ]] || ! "$acme" --version >/dev/null 2>&1; then fail_install 5 'acme.sh 未就绪'; fi
}
render_renew_units() {
  printf '%s\n' '[Unit]' 'Description=naiveproxy certificate renewal (acme.sh --cron)' 'After=network-online.target' 'Wants=network-online.target' '' '[Service]' 'Type=oneshot' 'ExecStart=/root/.acme.sh/acme.sh --cron --home /root/.acme.sh' >"$RENEW_SERVICE" || return 1
  printf '%s\n' '[Unit]' 'Description=Daily naiveproxy certificate renewal check' '' '[Timer]' 'OnCalendar=daily' 'RandomizedDelaySec=1h' 'Persistent=true' '' '[Install]' 'WantedBy=timers.target' >"$RENEW_TIMER"
}
check_ports() {
  local busy=0
  if systemctl is-active --quiet caddy 2>/dev/null; then
    err '检测到已有 Caddy 服务（caddy.service 处于 active）'
    busy=1
  fi
  if ss -ltnp 2>/dev/null | grep -q ':443 '; then
    err '443 已被占用：'
    ss -ltnp 2>/dev/null | grep ':443 ' | head -n 3 >&2
    busy=1
  fi
  if ss -ltn 2>/dev/null | grep -q ':80 '; then
    err '80 已被占用（acme.sh standalone 签发证书需要 80）：'
    ss -ltnp 2>/dev/null | grep ':80 ' | head -n 3 >&2
    busy=1
  fi
  if ((busy)); then
    err '请先释放端口：systemctl stop caddy'
    exit 7
  fi
}
track_file() { [[ -e $1 ]] || CREATED_FILES+=("$1"); }
track_dir() { [[ -d $1 ]] || CREATED_DIRS+=("$1"); }
rollback_install() {
  local f
  systemctl disable --now naive-cert-renew.timer naive-cert-renew.service >/dev/null 2>&1 || true
  systemctl disable --now caddy >/dev/null 2>&1 || true
  rm -f -- "$UNIT_FILE" "$RENEW_SERVICE" "$RENEW_TIMER"
  if ((ACME_INSTALLED)); then
    "${HOME:-/root}/.acme.sh/acme.sh" --uninstall --no-cron >/dev/null 2>&1 || true
    rm -rf -- "${HOME:-/root}/.acme.sh/"{acme.sh,acme.sh.env,acme.sh.csh,acme.sh.completion,dnsapi,deploy,notify}
  fi
  for f in ${CREATED_FILES[@]+"${CREATED_FILES[@]}"}; do
    if [[ -e $f ]]; then
      rm -f -- "$f" && msg "已回滚：删除 $f"
    fi
  done
  for f in ${CREATED_DIRS[@]+"${CREATED_DIRS[@]}"}; do
    if [[ $f == "$LOG_DIR" && -d $f ]] && rm -rf -- "$f"; then msg "已回滚：删除目录 $f"
    elif [[ -d $f ]] && rmdir -- "$f" 2>/dev/null; then
      msg "已回滚：删除空目录 $f"
    fi
  done
  systemctl daemon-reload >/dev/null 2>&1 || true
  if ((NEWLY_ISSUED)); then
    msg '证书已签发并保留于 /root/.acme.sh，本次消耗 1 次签发配额；请勿手动重复签发'
  fi
  ACME_INSTALLED=0 CREATED_FILES=()
  CREATED_DIRS=()
}
fail_install() {
  local code=$1
  shift
  err "安装失败：$*"
  if ((INSTALLING)); then
    rollback_install
    INSTALLING=0
  fi
  exit "$code"
}

on_error() {
  local rc=$?
  if ((INSTALLING)); then
    err "安装失败：出现未预期错误（exit ${rc}）"
    rollback_install
    INSTALLING=0
    exit "$rc"
  fi
}

on_exit() {
  local rc=$?
  if [[ -n $TMP_DIR && -d $TMP_DIR ]]; then
    rm -rf -- "$TMP_DIR"
  fi
  if ((INSTALLING)) && ((rc != 0)); then
    rollback_install
  fi
  exit "$rc"
}

render_caddyfile() {
  cat <<EOF
{
	admin off
	auto_https off
	order forward_proxy before file_server
}

:443, ${STATE_DOMAIN} {
	tls ${STATE_CERT} ${STATE_KEY}

	forward_proxy {
		basic_auth ${STATE_USER} ${STATE_PASS}
		hide_ip
		hide_via
		probe_resistance ${STATE_PROBE}
	}

	file_server {
		root ${WEB_ROOT}
	}

	log {
		output file ${LOG_DIR}/access.log {
			roll_size 20MiB
			roll_keep 5
			roll_keep_for 168h
		}
	}
}
EOF
}

render_unit() {
  cat <<'EOF'
[Unit]
Description=Caddy (naiveproxy)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
}

render_hook() {
  cat <<'EOF'
#!/bin/bash
set -e
systemctl restart caddy
EOF
}

render_index() {
  cat <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Welcome</title>
<style>
  html { font-family: -apple-system, "Segoe UI", Roboto, Arial, sans-serif; }
  body { margin: 0; display: flex; min-height: 100vh; align-items: center; justify-content: center; background: #f6f7f9; color: #24292f; }
  main { text-align: center; padding: 2rem; }
  h1 { font-size: 1.6rem; font-weight: 600; margin: 0 0 .6rem; }
  p { margin: 0; color: #57606a; }
</style>
</head>
<body>
<main>
<h1>Welcome</h1>
<p>This site is under construction.</p>
</main>
</body>
</html>
EOF
}

load_state() {
  [[ -f $STATE_FILE ]] || return 1
  local owner mode
  owner=$(stat -c '%U' -- "$STATE_FILE" 2>/dev/null) || return 1
  mode=$(stat -c '%a' -- "$STATE_FILE" 2>/dev/null) || return 1
  if [[ $owner != 'root' ]]; then
    err "状态文件属主为 ${owner}，拒绝加载"
    exit 3
  fi
  if ((8#$mode & 8#077)); then
    err "状态文件权限 ${mode} 宽于 0600，拒绝加载"
    exit 3
  fi
  set -a
  # shellcheck source=/dev/null
  . "$STATE_FILE"
  set +a
  : "${STATE_DOMAIN:=}" "${STATE_USER:=}" "${STATE_PASS:=}" "${STATE_PROBE:=}"
  return 0
}

save_state() {
  local old
  old=$(umask)
  track_file "$STATE_FILE"
  umask 077
  {
    printf 'STATE_VERSION=1\n'
    printf 'STATE_DOMAIN=%s\n' "$STATE_DOMAIN"
    printf 'STATE_USER=%s\n' "$STATE_USER"
    printf 'STATE_PASS=%s\n' "$STATE_PASS"
    printf 'STATE_PROBE=%s\n' "$STATE_PROBE"
    printf 'STATE_PORT=443\n'
    printf 'STATE_CERT=%s\n' "$STATE_CERT"
    printf 'STATE_KEY=%s\n' "$STATE_KEY"
    printf 'STATE_CADDY_SHA=%s\n' "$CADDY_SHA256"
    printf 'STATE_INSTALLED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$STATE_FILE" || {
    umask "$old"
    return 1
  }
  umask "$old"
  chmod 0600 "$STATE_FILE" && chown root:root "$STATE_FILE"
}

show_client() {
  local domain=${1:-$STATE_DOMAIN} user=${2:-$STATE_USER} pass=${3:-$STATE_PASS}
  msg '===== 客户端配置 ====='
  printf '服务器    %s:443\n' "$domain"
  printf '用户名    %s\n' "$user"
  printf '密码      %s\n' "$pass"
  printf '链接      naive+https://%s:%s@%s:443#%s\n' \
    "$(pct_encode "$user")" "$(pct_encode "$pass")" "$domain" "$domain"
  printf '伪装站    https://%s/            （未认证访问可见）\n' "$domain"
}

install_flow() {
  if [[ -f $STATE_FILE ]] && systemctl is-active --quiet caddy 2>/dev/null; then
    load_state 2>/dev/null || true
    msg "已安装（域名 ${STATE_DOMAIN:-?}，用户 ${STATE_USER:-?}），如需重装请先选 5 卸载"
    return 0
  fi

  local deps_summary; deps_summary=$(ensure_deps) || exit 3
  check_ports

  msg '===== 安装 naiveproxy ====='
  local domain email user pass probe

  domain=$(ask_domain) || { err '输入结束'; exit 1; }
  email=$(ask_email) || { err '输入结束'; exit 1; }
  user=$(ask_user) || { err '输入结束'; exit 1; }

  local dns_rc=0
  check_dns "$domain" || dns_rc=$?
  if [[ $dns_rc -eq 8 ]]; then
    exit 8
  elif [[ $dns_rc -ne 0 ]]; then
    msg '已取消，返回菜单'
    return 0
  fi

  pass=$(gen_secret 24)
  probe=$(gen_secret 24)
  [[ $pass =~ ^[A-Za-z0-9]{24}$ ]] || { err '密码生成不符合字符集'; exit 1; }
  [[ $probe =~ ^[A-Za-z0-9]{24}$ ]] || { err 'probe 值生成不符合字符集'; exit 1; }

  INSTALLING=1 ACME_INSTALLED=0 NEWLY_ISSUED=0
  TMP_DIR=$(mktemp -d) || fail_install 4 '无法创建临时目录'

  msg '下载 Caddy fork（linux/amd64）...'
  if ! curl -fL --connect-timeout 15 --max-time 600 -o "${TMP_DIR}/caddy.tar.xz" "$CADDY_URL"; then
    fail_install 4 '下载失败'
  fi

  local sum
  sum=$(sha256sum "${TMP_DIR}/caddy.tar.xz" 2>/dev/null | awk '{print $1}' || true)
  if [[ $sum != "$CADDY_SHA256" ]]; then
    fail_install 4 "sha256 校验失败：期望 ${CADDY_SHA256}，实际 ${sum}"
  fi

  tar -xJf "${TMP_DIR}/caddy.tar.xz" --strip-components=1 -C "$TMP_DIR" || fail_install 4 '解包失败'
  [[ -f "${TMP_DIR}/caddy" ]] || fail_install 4 '包内未找到 caddy 可执行文件'
  track_file "$CADDY_BIN"
  install -m 0755 "${TMP_DIR}/caddy" "$CADDY_BIN" || fail_install 4 '安装 caddy 二进制失败'

  if ! id -u caddy >/dev/null 2>&1; then
    useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin caddy \
      || fail_install 1 '创建 caddy 用户失败'
  fi

  local d
  for d in /etc/caddy "$DATA_DIR" "$LOG_DIR" "$WEB_ROOT"; do track_dir "$d"; done
  install -d -m 0755 -o root -g root /etc/caddy || fail_install 1 '创建 /etc/caddy 失败'
  install -d -m 0750 -o caddy -g caddy "$DATA_DIR" || fail_install 1 '创建数据目录失败'
  install -d -m 0750 -o caddy -g caddy "$LOG_DIR" || fail_install 1 '创建日志目录失败'
  install -d -m 0755 -o root -g root "$WEB_ROOT" || fail_install 1 '创建伪装站目录失败'

  track_file "$UNIT_FILE"
  if ! render_unit > "$UNIT_FILE"; then
    fail_install 1 '写 systemd 单元失败'
  fi
  chmod 0644 "$UNIT_FILE"
  systemctl daemon-reload || fail_install 1 'systemctl daemon-reload 失败'

  msg '安装 acme.sh ...'
  install_acme -- "$email"; ACME_INSTALLED=1
  local acme="${HOME:-/root}/.acme.sh/acme.sh" issue_rc=0

  msg '签发证书（standalone，80/443 会短暂停用）...'
  "$acme" --issue -d "$domain" --standalone --keylength ec-256 \
    --pre-hook 'systemctl stop caddy 2>/dev/null || true' \
    --post-hook 'systemctl start caddy 2>/dev/null || true' \
    --server letsencrypt || issue_rc=$?
  case $issue_rc in
    0) ;;
    2) msg '已有有效证书，跳过签发' ;;
    *) fail_install 5 '证书签发失败' ;;
  esac
  if [[ $issue_rc -eq 0 ]]; then NEWLY_ISSUED=1; fi
  track_file "$RELOAD_HOOK"
  if ! render_hook > "$RELOAD_HOOK"; then
    fail_install 1 '写续期钩子失败'
  fi
  chmod 0755 "$RELOAD_HOOK"

  track_dir "$CERT_DIR"
  install -d -m 0755 -o root -g caddy "$CERT_DIR" || fail_install 5 '创建证书目录失败'
  track_file "$CERT_FILE"
  track_file "$KEY_FILE"
  # 首次装证书时 Caddyfile 还不存在，此处不能挂 reloadcmd（钩子会 restart 失败并让 acme.sh 返回 1）。
  if ! "$acme" --install-cert -d "$domain" --ecc \
    --fullchain-file "$CERT_FILE" --key-file "$KEY_FILE"; then
    fail_install 5 '安装证书失败'
  fi
  chown root:caddy "$CERT_FILE" "$KEY_FILE"
  chmod 0644 "$CERT_FILE"
  chmod 0640 "$KEY_FILE"

  STATE_DOMAIN=$domain
  STATE_USER=$user
  STATE_PASS=$pass
  STATE_PROBE=$probe
  STATE_CERT=$CERT_FILE
  STATE_KEY=$KEY_FILE
  STATE_PORT=443

  track_file "$CADDYFILE"
  if ! render_caddyfile > "$CADDYFILE"; then
    fail_install 1 '写 Caddyfile 失败'
  fi
  chmod 0644 "$CADDYFILE"

  local vout=''
  if ! vout=$("$CADDY_BIN" validate --config "$CADDYFILE" --adapter caddyfile 2>&1); then
    err "$vout"
    fail_install 6 'Caddyfile 校验未通过'
  fi
  chown -R caddy:caddy "$LOG_DIR" || fail_install 1 '交还日志目录属主失败'
  track_file "${WEB_ROOT}/index.html"
  if ! render_index > "${WEB_ROOT}/index.html"; then
    fail_install 1 '写伪装站失败'
  fi
  chmod 0644 "${WEB_ROOT}/index.html"

  systemctl enable --now caddy || fail_install 1 '启用并启动 caddy 失败'
  local i st=''
  for i in 1 2 3; do
    st=$(systemctl is-active caddy 2>/dev/null || true)
    [[ $st == 'active' ]] && break
    sleep 1
  done
  if [[ $st != 'active' ]]; then
    journalctl -u caddy -n 20 --no-pager 2>/dev/null || true
    fail_install 1 'caddy 未能进入 active'
  fi

  # 服务已能正常拉起后再注册续期钩子（acme.sh 会把 Le_ReloadCmd 持久化，续期时执行）。
  if ! "$acme" --install-cert -d "$domain" --ecc \
    --fullchain-file "$CERT_FILE" --key-file "$KEY_FILE" \
    --reloadcmd "$RELOAD_HOOK" >/dev/null 2>&1; then
    fail_install 1 '注册证书续期钩子失败'
  fi
  chown root:caddy "$CERT_FILE" "$KEY_FILE"
  chmod 0644 "$CERT_FILE"
  chmod 0640 "$KEY_FILE"
  st=$(systemctl is-active caddy 2>/dev/null || true)
  [[ $st == 'active' ]] || fail_install 1 '注册续期钩子后服务未恢复 active'

  track_file "$RENEW_SERVICE"; track_file "$RENEW_TIMER"
  if ! { render_renew_units && chmod 0644 "$RENEW_SERVICE" "$RENEW_TIMER" && systemctl daemon-reload &&
    systemctl enable --now naive-cert-renew.timer && systemctl is-enabled --quiet naive-cert-renew.timer &&
    systemctl is-active --quiet naive-cert-renew.timer; }; then fail_install 1 '续期单元未就绪'; fi
  save_state || fail_install 1 '写状态文件失败'
  INSTALLING=0
  msg '安装完成'
  [[ -z $deps_summary ]] || msg "$deps_summary"
  show_client
}

do_status() {
  if ! load_state; then
    msg '未安装'
    return 0
  fi
  msg '===== 运行状态 ====='
  printf '服务状态  %s\n' "$(systemctl is-active caddy 2>/dev/null || true)"
  printf '监听端口  %s\n' "$(ss -ltnp 2>/dev/null | grep ':443 ' | awk '{print $4; exit}')"
  printf '域名      %s\n' "$STATE_DOMAIN"
  printf '用户名    %s\n' "$STATE_USER"
  if [[ -f ${STATE_CERT:-} ]]; then
    local end='' epoch=0 days=0
    end=$(openssl x509 -in "$STATE_CERT" -noout -enddate 2>/dev/null | cut -d= -f2)
    if [[ -n $end ]]; then
      epoch=$(date -d "$end" +%s 2>/dev/null || echo 0)
      ((epoch > 0)) && days=$(((epoch - $(date +%s)) / 86400))
      printf '证书到期  %s（剩余 %s 天）\n' "$end" "$days"
    fi
  fi
  printf '日志占用  %s\n' "$(du -sh "$LOG_DIR" 2>/dev/null | awk '{print $1}')"
}

do_logs() {
  journalctl -u caddy -n 50 --no-pager 2>/dev/null || true
  if [[ -f "${LOG_DIR}/access.log" ]]; then
    msg '----- access.log (tail -n 50) -----'
    tail -n 50 "${LOG_DIR}/access.log"
  fi
}

do_changepass() {
  if ! load_state; then
    msg '未安装'
    return 0
  fi
  printf '确认修改密码？输入 yes 继续: ' >&2
  local ans=''
  IFS= read -r ans || return 0
  if [[ $ans != 'yes' ]]; then
    msg '已取消'
    return 0
  fi

  local new backup="${CADDYFILE}.bak"
  new=$(gen_secret 24)
  if ! cp -p "$CADDYFILE" "$backup"; then
    err '备份 Caddyfile 失败'
    return 0
  fi
  sed -i -E "s|^([[:space:]]*basic_auth[[:space:]]+[^[:space:]]+[[:space:]]+)[^[:space:]]+[[:space:]]*$|\1${new}|" "$CADDYFILE"
  if ! "$CADDY_BIN" validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
    mv -f "$backup" "$CADDYFILE"
    err '新配置校验失败，已回滚'
    return 0
  fi
  if ! systemctl restart caddy; then
    mv -f "$backup" "$CADDYFILE"
    systemctl restart caddy >/dev/null 2>&1 || true
    err '重启失败，已回滚'
    return 0
  fi
  rm -f "$backup"
  sed -i "s|^STATE_PASS=.*$|STATE_PASS=${new}|" "$STATE_FILE"
  STATE_PASS=$new
  msg '密码已更新'
  show_client "$STATE_DOMAIN" "$STATE_USER" "$new"
}

do_uninstall() {
  if [[ ! -f $STATE_FILE ]]; then
    msg '未安装'
    return 0
  fi
  printf '确认卸载？输入 yes 继续: ' >&2
  local ans=''
  IFS= read -r ans || return 0
  if [[ $ans != 'yes' ]]; then
    msg '已取消'
    return 0
  fi

  systemctl disable --now caddy >/dev/null 2>&1 || true
  systemctl disable --now naive-cert-renew.timer >/dev/null 2>&1 || true
  rm -f "$RENEW_TIMER" "$RENEW_SERVICE"
  rm -f "$UNIT_FILE"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed caddy >/dev/null 2>&1 || true
  rm -rf /etc/caddy
  rm -f "$RELOAD_HOOK" "$CADDY_BIN"
  rm -rf "$WEB_ROOT"

  msg '已卸载 caddy 服务与配置'
  if ss -ltn 2>/dev/null | grep -q ':443 '; then
    msg '443 仍被占用'
  else
    msg '443 已释放'
  fi
  msg '保留目录：'
  local d
  for d in "$DATA_DIR" "$LOG_DIR" "$CERT_DIR"; do
    [[ -d $d ]] && msg "  $d"
  done
  msg "彻底删除证书：rm -rf ${CERT_DIR} /root/.acme.sh"
  msg '系统依赖包未回滚（apt 补装的包保持安装状态，本脚本无法区分系统原有包与他服务在用包）'
}

menu_loop() {
  local choice=''
  while :; do
    printf '\n%s\n' '===== naiveproxy 管理菜单 ====='
    printf '%s\n' '1) 安装'
    printf '%s\n' '2) 查看状态'
    printf '%s\n' '3) 查看日志'
    printf '%s\n' '4) 修改密码'
    printf '%s\n' '5) 卸载'
    printf '请选择 [1-5]: '
    if ! IFS= read -r choice; then
      printf '\n'
      return 0
    fi
    case "$choice" in
      1) install_flow ;;
      2) do_status ;;
      3) do_logs ;;
      4) do_changepass ;;
      5) do_uninstall ;;
      *) msg '无效选项' ;;
    esac
  done
}

main() {
  trap 'on_error' ERR
  trap 'on_exit' EXIT
  preflight
  menu_loop
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main
fi
