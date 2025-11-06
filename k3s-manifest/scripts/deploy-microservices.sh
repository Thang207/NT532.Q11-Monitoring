#!/usr/bin/env bash
set -euo pipefail

# ========= Config =========
NS="demo"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
APP_DIR="$ROOT_DIR/microservices"
INGRESS_NS="ingress-nginx"
INGRESS_SVC="ingress-nginx-controller"

API_A_DIR="$APP_DIR/api-a"
API_B_DIR="$APP_DIR/api-b"
FE_DIR="$APP_DIR/frontend"
ING_DIR="$APP_DIR/ingress"
AUTO_DIR="$APP_DIR/autoscaling"

KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"

# ========= Helpers =========
die() { echo "❌ $*" >&2; exit 1; }
ok()  { echo "✅ $*"; }
info(){ echo "ℹ️  $*"; }

need_bin() {
  command -v "$1" >/dev/null 2>&1 || die "Thiếu binary: $1"
}

ns_exists() {
  $KUBECTL_BIN get ns "$1" >/dev/null 2>&1
}

apply_if_exists() {
  local f="$1"
  if [[ -f "$f" ]]; then
    $KUBECTL_BIN apply -f "$f"
  else
    info "Bỏ qua (không tìm thấy): $f"
  fi
}

wait_deploy_ready() {
  local ns="$1" name="$2" timeout="${3:-180s}"
  info "Chờ Deployment $name (ns=$ns) sẵn sàng (timeout $timeout)..."
  $KUBECTL_BIN -n "$ns" rollout status deploy/"$name" --timeout="$timeout"
}

get_any_node_public_ip() {
  # Thử lấy public IP của master trước; nếu không có thì lấy của node bất kỳ
  local ip
  ip="$($KUBECTL_BIN get nodes -o wide | awk 'NR>1{print $7; exit}')" || true
  echo "$ip"
}

print_access_info() {
  echo
  info "Kiểm tra Service Ingress (${INGRESS_NS}/${INGRESS_SVC})..."
  if ! $KUBECTL_BIN -n "$INGRESS_NS" get svc "$INGRESS_SVC" >/dev/null 2>&1; then
    info "Không tìm thấy service Ingress. Hãy đảm bảo bạn đã cài ingress-nginx bằng Helm."
    return 0
  fi

  local type ext_ip ports
  type="$($KUBECTL_BIN -n "$INGRESS_NS" get svc "$INGRESS_SVC" -o jsonpath='{.spec.type}')"
  ext_ip="$($KUBECTL_BIN -n "$INGRESS_NS" get svc "$INGRESS_SVC" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  ports="$($KUBECTL_BIN -n "$INGRESS_NS" get svc "$INGRESS_SVC" -o jsonpath='{.spec.ports[*].nodePort}' 2>/dev/null || true)"

  if [[ "$type" == "LoadBalancer" && -n "${ext_ip:-}" ]]; then
    ok "Ingress Service kiểu LoadBalancer có EXTERNAL-IP: $ext_ip"
    echo "🌐 Thử truy cập:  http://$ext_ip/"
    echo "🔌 API-A:         http://$ext_ip/api/a/"
    echo "🔌 API-B:         http://$ext_ip/api/b/"
  else
    # NodePort hoặc K3s ServiceLB (EXTERNAL-IP thường <pending>)
    local node_ip http_np https_np
    node_ip="$(get_any_node_public_ip)"
    if [[ -z "$node_ip" ]]; then
      info "Không lấy được Public IP node. Bạn có thể điền tay IP của master/worker."
      return 0
    fi
    # Lấy NodePort nếu có
    http_np="$($KUBECTL_BIN -n "$INGRESS_NS" get svc "$INGRESS_SVC" -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || true)"
    https_np="$($KUBECTL_BIN -n "$INGRESS_NS" get svc "$INGRESS_SVC" -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}' 2>/dev/null || true)"

    if [[ -n "$http_np" ]]; then
      ok "Ingress đang ở chế độ ${type:-NodePort}/ServiceLB. Dùng Node IP + NodePort:"
      echo "🌐 HTTP:  http://$node_ip:$http_np/"
      echo "🔌 API-A: http://$node_ip:$http_np/api/a/"
      echo "🔌 API-B: http://$node_ip:$http_np/api/b/"
    else
      # Nhiều setup K3s ServiceLB bind hostPort 80/443; thử thẳng 80/443
      ok "Thử truy cập trực tiếp 80/443 (K3s ServiceLB có thể bind hostPort):"
      echo "🌐 HTTP:  http://$node_ip/"
      echo "🔌 API-A: http://$node_ip/api/a/"
      echo "🔌 API-B: http://$node_ip/api/b/"
    fi
  fi

  echo
  info "Ingress rules trong namespace '$NS':"
  $KUBECTL_BIN -n "$NS" get ingress -o wide || true
}

apply_all() {
  need_bin "$KUBECTL_BIN"

  # 0) Namespace
  if ns_exists "$NS"; then
    info "Namespace '$NS' đã tồn tại."
  else
    $KUBECTL_BIN apply -f "$APP_DIR/namespace.yaml"
    ok "Tạo namespace '$NS'"
  fi

  # 1) API-A
  info "Triển khai API-A..."
  apply_if_exists "$API_A_DIR/configmap.yaml"
  apply_if_exists "$API_A_DIR/deployment.yaml"
  apply_if_exists "$API_A_DIR/service.yaml"
  wait_deploy_ready "$NS" "api-a"

  # 2) API-B
  info "Triển khai API-B..."
  apply_if_exists "$API_B_DIR/configmap.yaml"
  apply_if_exists "$API_B_DIR/deployment.yaml"
  apply_if_exists "$API_B_DIR/service.yaml"
  wait_deploy_ready "$NS" "api-b"

  # 3) Frontend
  info "Triển khai Frontend..."
  apply_if_exists "$FE_DIR/configmap.yaml"
  apply_if_exists "$FE_DIR/deployment.yaml"
  apply_if_exists "$FE_DIR/service.yaml"
  wait_deploy_ready "$NS" "frontend"

  # 4) Ingress
  info "Áp dụng Ingress rules..."
  apply_if_exists "$ING_DIR/demo-ingress.yaml"

  # 5) (Optional) HPA nếu có
  if [[ -d "$AUTO_DIR" ]]; then
    info "Áp dụng autoscaling (nếu có tệp)..."
    for f in "$AUTO_DIR"/*.yaml; do
      [[ -e "$f" ]] || continue
      $KUBECTL_BIN apply -f "$f"
    done
  fi

  ok "Triển khai xong!"
  $KUBECTL_BIN -n "$NS" get pods,svc,ingress
  print_access_info
}

delete_all() {
  need_bin "$KUBECTL_BIN"

  info "Xoá ingress..."
  $KUBECTL_BIN delete -f "$ING_DIR/demo-ingress.yaml" --ignore-not-found

  info "Xoá frontend..."
  $KUBECTL_BIN delete -f "$FE_DIR/service.yaml" --ignore-not-found
  $KUBECTL_BIN delete -f "$FE_DIR/deployment.yaml" --ignore-not-found
  $KUBECTL_BIN delete -f "$FE_DIR/configmap.yaml" --ignore-not-found

  info "Xoá API-B..."
  $KUBECTL_BIN delete -f "$API_B_DIR/service.yaml" --ignore-not-found
  $KUBECTL_BIN delete -f "$API_B_DIR/deployment.yaml" --ignore-not-found
  $KUBECTL_BIN delete -f "$API_B_DIR/configmap.yaml" --ignore-not-found

  info "Xoá API-A..."
  $KUBECTL_BIN delete -f "$API_A_DIR/service.yaml" --ignore-not-found
  $KUBECTL_BIN delete -f "$API_A_DIR/deployment.yaml" --ignore-not-found
  $KUBECTL_BIN delete -f "$API_A_DIR/configmap.yaml" --ignore-not-found

  info "Xoá HPA (nếu có)..."
  if [[ -d "$AUTO_DIR" ]]; then
    for f in "$AUTO_DIR"/*.yaml; do
      [[ -e "$f" ]] || continue
      $KUBECTL_BIN delete -f "$f" --ignore-not-found
    done
  fi

  info "Xoá namespace (tùy chọn)..."
  $KUBECTL_BIN delete ns "$NS" --ignore-not-found

  ok "Đã xoá microservices trong ns '$NS'."
}

usage() {
  cat <<EOF
Sử dụng: $(basename "$0") <apply|delete>

  apply   - Triển khai namespace, backend (api-a, api-b), frontend, ingress (+ HPA nếu có)
  delete  - Gỡ toàn bộ tài nguyên và namespace demo

Biến môi trường:
  KUBECTL_BIN   - đường dẫn kubectl (mặc định: kubectl)
EOF
}

# ========= Main =========
cmd="${1:-}"
case "$cmd" in
  apply)  apply_all ;;
  delete) delete_all ;;
  *)      usage; exit 1 ;;
esac
