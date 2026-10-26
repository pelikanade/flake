#!/usr/bin/env bash
# The slow half of the panel: everything that needs a process, a bus or the
# cluster API, gathered once and left in /run/alioth-panel/status.env for the
# renderer. Written to a temporary file and renamed, so the renderer never reads
# a half-written sample; every value is allowed to come out empty and render as
# n/a rather than making this fail.
#
# Keys the renderer reads (keep the two files in step):
#   sample_epoch gen disk services_ok
#   wifi_addr usb_addr ts_addr tailnet tailnet_short
#   k3s_short nodes_short pods_short k3s_detail
#   rank_head rank_row1 rank_row2 rank_row3 rank_cpu rank_mem
#   top_short top firewall_short firewall watchdog_short watchdog
#   addresses ssh_sessions
set -u

PATH=/run/current-system/sw/bin
run=${ALIOTH_PANEL_RUN:-/run/alioth-panel}
mkdir -p "$run"

# --- brightness bands -------------------------------------------------------
# The panel is on all day, so it never sits at the console's default: dim for
# the day and dimmer for the evening, with the backlight at its floor overnight
# — the frame is black there anyway, and kmscon owns the DRM device, so
# `fb0/blank` is not what turns this panel down.
hour=$(printf '%(%H)T' -1)
case "$hour" in
  0[6-9] | 1[0-9] | 2[0-1]) bright=150 ;;
  2[2-3]) bright=60 ;;
  *) bright=1 ;;
esac
if [ "$(cat "$run/band" 2>/dev/null)" != "$bright" ]; then
  echo "$bright" >/sys/class/backlight/ae94000.dsi.0/brightness 2>/dev/null
  printf '%s\n' "$bright" >"$run/band"
fi

# --- helpers ----------------------------------------------------------------
active() {
  case "$(systemctl is-active "$1" 2>/dev/null)" in
    active) echo ok ;;
    *) echo no ;;
  esac
}
addr4() { ip -4 -o addr show "$1" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1; }

# --- services ---------------------------------------------------------------
units="sshd tailscaled k3s systemd-networkd wpa_supplicant nftables alioth-charge-window"
ok=0 total=0 bad=""
for unit in $units; do
  total=$((total + 1))
  if [ "$(active "$unit")" = ok ]; then
    ok=$((ok + 1))
  else
    bad+="$unit "
  fi
done
services_ok="$ok/$total ok"
[ -n "$bad" ] && services_ok="$ok/$total 异常: $bad"

# --- tailscale --------------------------------------------------------------
ts_json=$(timeout 10 tailscale status --json 2>/dev/null)
ts_state=$(printf '%s' "$ts_json" | grep -o '"BackendState": "[^"]*"' | cut -d'"' -f4)
ts_ip=$(printf '%s' "$ts_json" | grep -o '"100\.[0-9.]*"' | head -1 | tr -d '"')
self_name=$(printf '%s' "$ts_json" | grep -o '"DNSName": "[^"]*"' | head -1 | cut -d'"' -f4)
peers_total=$(printf '%s' "$ts_json" | grep -c '"DNSName"')
peers_online=$(printf '%s' "$ts_json" | grep -c '"Online": true')
tailnet="${ts_state:-n/a}  $((peers_total - 1)) 节点 ($((peers_online)) 在线)  ${self_name%%.*}"

# --- the cluster ------------------------------------------------------------
k3s_short="未运行"
nodes_short=""
pods_short=""
k3s_detail=""
rank_head=""
rank_row1="" rank_row2="" rank_row3=""
rank_cpu="" rank_mem=""
if systemctl is-active --quiet k3s && command -v kubectl >/dev/null; then
  readyz=$(timeout 15 kubectl get --raw=/readyz 2>/dev/null | head -c 2)
  [ -n "$readyz" ] && readyz=ok || readyz=no
  version=$(timeout 15 kubectl version -o json 2>/dev/null | grep -o '"gitVersion": "[^"]*"' | tail -1 | cut -d'"' -f4)
  k3s_short="readyz $readyz  ${version#v}"
  nodes_short=$(timeout 15 kubectl get nodes --no-headers 2>/dev/null | awk '{printf "%s %s  ", $1, $2}')
  pods_short=$(timeout 20 kubectl get pods -A --no-headers 2>/dev/null | awk '{print $4}' | sort | uniq -c | awk '{printf "%s %s  ", $1, $2}')
  deploys=$(timeout 15 kubectl get deploy -A --no-headers 2>/dev/null | awk '{print $3}' | tr '\n' ' ')
  k3s_detail="readyz $readyz   ${version:-n/a}   deploy(就绪/期望): $deploys"

  # A pod's name is its deployment plus a replica-set hash and an id; dropping
  # the last two fields leaves the deployment, which is the name worth printing.
  # One `|` between rows, spaces inside one.
  rank() { # rank <sort-by> <lines>
    timeout 25 kubectl top pods -A --sort-by="$1" --no-headers 2>/dev/null |
      awk -v n="$2" 'NR<=n { name=$2; sub(/-[^-]+-[^-]+$/, "", name); printf "%s %s %s\n", name, $3, $4 }' | paste -sd'|' -
  }
  rank_cpu=$(rank cpu 5)
  rank_mem=$(rank memory 5)
fi

# --- the rest ---------------------------------------------------------------
# `ps` reports CPU use averaged over a process's whole life, so a helper that
# has just started outranks everything else; the busiest process worth naming
# is the first that is neither such a tool nor one of this script's children.
top=$(ps -eo pcpu=,comm= --sort=-pcpu 2>/dev/null |
  awk '$2 !~ /^(ps|awk|sed|tr|cut|head|tail|sort|uniq|wc|grep|cat|systemctl|systemd(-.*)?|journalctl|kubectl|tailscale|nft|find|date|hostname|sh|bash|timeout|alioth-panel-collect|run-parts)$/ { printf "%s %s%%", $2, $1; exit }')
firewall="nftables $(active nftables)  $(nft list ruleset 2>/dev/null | wc -l) 条规则"
watchdog=$(systemctl show -p RuntimeWatchdogUSec -p WatchdogDevice 2>/dev/null |
  awk -F= '/RuntimeWatchdogUSec/{gsub(/[^0-9]/,"",$2); t=$2} /WatchdogDevice/{d=$2} END{printf "%s  %ss", d, t}')
disk=$(df -h / 2>/dev/null | awk 'NR == 2 {printf "%s/%s (%s)", $3, $2, $5}')
gen=$(basename "$(readlink /nix/var/nix/profiles/system 2>/dev/null)" 2>/dev/null)
wifi_addr=$(addr4 wlp1s0)
usb_addr=$(addr4 usb0)
ts_addr=${ts_ip:-$(addr4 tailscale0)}

# The share of the CPUs the machine is actually using, over one second:
# /proc/stat only carries cumulative counters, so a single reading says nothing.
cpu_sample() {
  awk '/^cpu / {print $2 + $3 + $4 + $6 + $7 + $8, $5 + $6}' /proc/stat
}
set -- $(cpu_sample)
busy1=$1 idle1=$2
sleep 1
set -- $(cpu_sample)
busy2=$1 idle2=$2
cpu_used=$(awk -v b1="$busy1" -v i1="$idle1" -v b2="$busy2" -v i2="$idle2" \
  'BEGIN { dt = (b2 + i2) - (b1 + i1); di = i2 - i1; printf "%.1f", (dt > 0 ? 100 * (1 - di / dt) : 0) }')

# What the port negotiated: the charger lists its BC1.2 types with the active
# one in brackets, and the type-C port names a PD contract when it has one.
usb_type=$(cat /sys/class/power_supply/pm8150b-charger/usb_type 2>/dev/null)
active_type=$(printf '%s' "$usb_type" | grep -o '\[[^]]*\]' | tr -d '[]')
pd_revision=$(cat /sys/class/typec/port0/usb_power_delivery_revision 2>/dev/null)
if [ "$(cat /sys/class/power_supply/pm8150b-charger/online 2>/dev/null)" != "1" ]; then
  charger=offline
elif [ -n "$pd_revision" ]; then
  charger="PD"
else
  charger="${active_type:-unknown}"
fi

# --- write it ---------------------------------------------------------------
# Plain key=value lines for the panel program to read: nothing needs quoting,
# and any newline a command produced is folded to a space so a single value
# cannot tear the file apart.
tmp=$run/status.env.tmp
kv() { printf '%s=%s\n' "$1" "${2//$'\n'/ }"; }
{
  kv sample_epoch "$EPOCHSECONDS"
  kv gen "$gen"
  kv disk "$disk"
  kv charger "$charger"
  kv services_ok "$services_ok"
  kv wifi_addr "$wifi_addr"
  kv usb_addr "$usb_addr"
  kv ts_addr "$ts_addr"
  kv tailnet "$tailnet"
  kv k3s_short "$k3s_short"
  kv nodes_short "$nodes_short"
  kv pods_short "$pods_short"
  kv k3s_detail "$k3s_detail"
  kv rank_cpu "$rank_cpu"
  kv rank_mem "$rank_mem"
  kv top "$top"
  kv cpu_used "$cpu_used"
  kv firewall "$firewall"
  kv watchdog "$watchdog"
} >"$tmp" && mv "$tmp" "$run/status.env"
