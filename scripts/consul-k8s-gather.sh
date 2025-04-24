#!/usr/bin/env sh
#
# consul-k8s-gather.sh
#
# POSIX-compliant script to:
# 1. Ensure consul-k8s CLI is installed. If not found, attempt to install it.
# 2. Collect troubleshooting data for Consul-K8s proxies in a given namespace.
#    Optionally filter by a substring in the proxy/pod name (the --service param).
#
# Usage:
#   consul-k8s-gather.sh [--namespace <NAMESPACE>] [--context <CONTEXT>] [--service <NAME>] [--help]
#   Or with '=' syntax:
#   consul-k8s-gather.sh --namespace=<NAMESPACE> --context=<CONTEXT> --service=<NAME>
#
# Defaults:
#   --namespace: "default"
#   --context:   (uses the current kubectl context)
#   --service:   (no filter, captures all proxies)

# -----------------------
# 0) Helper: usage
# -----------------------
usage() {
  echo "Usage: $0 [OPTIONS]"
  echo "Ensures consul-k8s CLI is installed, then collects data for proxies in a namespace."
  echo ""
  echo "Options:"
  echo "  --namespace <NAMESPACE>      Kubernetes namespace (default: \"default\")."
  echo "  --context <CONTEXT>          Kube context to use (default: current context)."
  echo "  --service <NAME>             Only collect data for pods whose names contain <NAME>."
  echo "  --help                       Show usage info."
  exit 0
}

# -----------------------
# A) Attempted installation function
# -----------------------
install_consul_k8s() {
  echo "Attempting to install consul-k8s CLI..."

  # Detect if running macOS (Darwin) or Linux
  # For Linux, further detect Debian/Ubuntu vs. CentOS/RHEL with basic pattern matching
  # We assume 'uname' is available
  OS_TYPE="$(uname -s 2>/dev/null || echo "unknown")"

  if [ "$OS_TYPE" = "Darwin" ]; then
    # macOS
    # We expect Homebrew to be installed. If not, exit with instructions.
    if command -v brew >/dev/null 2>&1; then
      echo "Detected macOS. Installing consul-k8s via Homebrew..."
      brew tap hashicorp/tap || {
        echo "Failed to tap hashicorp/tap Homebrew repo." >&2
        return 1
      }
      brew install hashicorp/tap/consul-k8s || {
        echo "Failed to install consul-k8s via Homebrew." >&2
        return 1
      }
    else
      echo "Homebrew not found! Please install Homebrew or manually install consul-k8s." >&2
      return 1
    fi

  elif [ "$OS_TYPE" = "Linux" ]; then
    # Linux
    # Check /etc/os-release or lsb_release output for 'Ubuntu', 'Debian', 'CentOS', 'RHEL'
    if [ -r "/etc/os-release" ]; then
      # shellcheck disable=SC2002
      OS_INFO="$(cat /etc/os-release | tr '[:upper:]' '[:lower:]')"
      # Use substring checks
      case "$OS_INFO" in
        *ubuntu*|*debian*)
          echo "Detected Ubuntu/Debian Linux. Installing consul-k8s via apt..."
          # The following uses the official instructions
          # shellcheck disable=SC2016
          sh -c 'curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -'
          sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
          # shellcheck disable=2015
          sudo apt-get update && sudo apt-get install -y consul-k8s || {
            echo "Failed to install consul-k8s via apt." >&2
            return 1
          }
          ;;
        *centos*|*rhel*|*red\ hat*)
          echo "Detected CentOS/RHEL. Installing consul-k8s via yum..."
          sudo yum install -y yum-utils || {
            echo "Failed to install yum-utils." >&2
            return 1
          }
          sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo || {
            echo "Failed to add HashiCorp repo." >&2
            return 1
          }
          sudo yum -y install consul-k8s || {
            echo "Failed to install consul-k8s via yum." >&2
            return 1
          }
          ;;
        *)
          echo "Unrecognized Linux distro in /etc/os-release:"
          echo "$OS_INFO"
          echo "Please install consul-k8s manually. Exiting." >&2
          return 1
          ;;
      esac
    else
      echo "Unknown Linux distro, /etc/os-release not found or unreadable."
      echo "Please manually install consul-k8s." >&2
      return 1
    fi
  else
    # Neither Darwin nor Linux
    echo "Unsupported OS '$OS_TYPE'. Please install consul-k8s manually." >&2
    return 1
  fi

  # Verify the installation
  if command -v consul-k8s >/dev/null 2>&1; then
    echo "consul-k8s successfully installed."
    return 0
  else
    echo "consul-k8s installation attempted but not found on PATH. Please install manually." >&2
    return 1
  fi
}

# -----------------------------------------
# 3) Parse args
# -----------------------------------------
namespace="default"; kube_context=""; service=""
while [ $# -gt 0 ]; do
  case "$1" in
    --namespace=*|-n=*) namespace="${1#*=}";;
    --namespace|-n) shift; namespace="$1";;
    --context=*|-c=*) kube_context="${1#*=}";;
    --context|-c) shift; kube_context="$1";;
    --service=*|-s=*) service="${1#*=}";;
    --service|-s) shift; service="$1";;
    --help|-h) usage;;
    --*) echo "Unknown option: $1"; usage;;
    *) break;;
  esac
  shift
done

# -----------------------
# C) Ensure consul-k8s is installed
# -----------------------
if ! command -v consul-k8s >/dev/null 2>&1; then
  echo "consul-k8s not found on PATH. Attempting installation..."
  if ! install_consul_k8s; then
    echo "Failed to install consul-k8s automatically. Exiting." >&2
    exit 1
  fi
fi

# -----------------------
# D) Setup output folder
# -----------------------
timestamp="$(date +%Y%m%d%H%M%S)"
out_dir="consul_k8s_support_${namespace}_${timestamp}"
mkdir -p "$out_dir"

echo "Gathering consul-k8s troubleshooting data for namespace '$namespace'."
[ -n "$service" ] && echo "Filtering proxies whose names contain the substring: '$service'"
echo "Output directory: $out_dir"

# Optional --context flag
ctx_flag=""
if [ -n "$kube_context" ]; then
  ctx_flag="--context $kube_context"
fi

# -----------------------
# E) Collect data
# -----------------------

# (1) Overall Consul-K8s status
echo "1) Collecting 'consul-k8s status'..."
# shellcheck disable=2086
consul-k8s status $ctx_flag > "${out_dir}/consul-k8s_status.txt" 2>&1

# (2) List all proxies in the namespace
echo "2) Collecting 'consul-k8s proxy list' for namespace '$namespace'..."
# shellcheck disable=2086
consul-k8s proxy list $ctx_flag --namespace "$namespace" > "${out_dir}/proxy_list.txt" 2>&1

# (3) Gather data for each matching proxy in the namespace
echo "3) Collecting detailed data for each proxy..."

## Make a named pipe for POSIX compliant reading of the proxy list
## https://mywiki.wooledge.org/BashFAQ/024
## https://mywiki.wooledge.org/NamedPipes
mkfifo proxy_pipe
found_proxy="false"
awk '/Name[ \t]+Type/{found=1; next} found{print}' "${out_dir}/proxy_list.txt" > proxy_pipe &
while IFS= read -r line; do
  [ -z "$line" ] && continue

  # shellcheck disable=2086
  set -- $line
  proxy_name="$1"
  proxy_type="$2"

  # If --service is set, filter by substring match in the proxy name
  if [ -n "$service" ]; then
    case "$proxy_name" in
      *"$service"*)
        ;;
      *)
        continue
        ;;
    esac
  fi

  found_proxy="true"
  mkdir -p "${out_dir}/${proxy_name}"

  echo "   -> Gathering data for proxy: $proxy_name ($proxy_type)"

  # consul-k8s proxy read: table, json, raw
  # shellcheck disable=2086
  consul-k8s proxy read "$proxy_name" $ctx_flag --namespace "$namespace" \
    > "${out_dir}/${proxy_name}/proxy_read_table.txt" 2>&1

  # shellcheck disable=2086
  consul-k8s proxy read "$proxy_name" $ctx_flag --namespace "$namespace" --output json \
    > "${out_dir}/${proxy_name}/proxy_read.json" 2>&1

  # shellcheck disable=2086
  consul-k8s proxy read "$proxy_name" $ctx_flag --namespace "$namespace" --output raw \
    > "${out_dir}/${proxy_name}/proxy_read_raw.json" 2>&1

  # consul-k8s proxy stats
  # shellcheck disable=2086
  consul-k8s proxy stats "$proxy_name" $ctx_flag --namespace "$namespace" \
    > "${out_dir}/${proxy_name}/proxy_stats.txt" 2>&1

  # consul-k8s proxy log
  # shellcheck disable=2086
  consul-k8s proxy log "$proxy_name" $ctx_flag --namespace "$namespace" \
    > "${out_dir}/${proxy_name}/proxy_log_levels.txt" 2>&1

  # consul-k8s troubleshoot upstreams
  # shellcheck disable=2086
  consul-k8s troubleshoot upstreams --pod "$proxy_name" $ctx_flag --namespace "$namespace" \
    > "${out_dir}/${proxy_name}/troubleshoot_upstreams.txt" 2>&1

  # Additional "consul-k8s troubleshoot proxy" commands can be added here if you
  # know the specific upstream IPs or envoy-ids you want to check.
done < proxy_pipe

if [ "$found_proxy" = "false" ]; then
  echo "No proxies found in namespace '$namespace' matching service substring '$service'."
  exit
fi

# -----------------------
# F) Create archive
# -----------------------
tarball="${out_dir}.tar.gz"
echo "4) Compressing results into '$tarball'..."
tar -czf "$tarball" "$out_dir"

echo "Collection complete."
echo "Troubleshooting data is in directory '$out_dir' and archived as '$tarball'."