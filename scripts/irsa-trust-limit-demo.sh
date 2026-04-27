#!/usr/bin/env bash
# IRSA trust policy 길이 한도(default 2048자) 데모.
#
# 흐름:
#   provision : fake OIDC provider N개를 IAM에 등록
#   run       : 한 IAM Role 의 trust policy 에 entry 를 1개씩 늘려가며
#               update-assume-role-policy 호출, 길이/성공/에러 기록
#   cleanup   : 생성한 Role + OIDC provider 모두 삭제
#
# 가정:
#   - AWS_PROFILE 또는 기본 자격증명이 personal 계정을 가리킨다
#   - region: ap-northeast-2 (변경 시 REGION env 사용)
#   - trust policy 길이 quota: default 2048 (증액 미신청 상태)
set -euo pipefail

# ---- config ----
REGION="${REGION:-ap-northeast-2}"
ROLE_NAME="${ROLE_NAME:-role-trust-limit-demo}"
PROVIDER_ID_PREFIX="${PROVIDER_ID_PREFIX:-DEMO00000000000000000000000000}"  # 32-char id 의 앞 30자
SERVICE_ACCOUNT_SUB="${SERVICE_ACCOUNT_SUB:-system:serviceaccount:external-dns:external-dns}"
TARGET_COUNT="${TARGET_COUNT:-12}"
# DST Root CA X3 (널리 알려진 공개 thumbprint, fake provider 등록용 placeholder)
THUMBPRINT="${THUMBPRINT:-9e99a48a9960b14926bb7f3b02e22da2b0ab7280}"
AUDIENCE="${AUDIENCE:-sts.amazonaws.com}"

# ---- paths ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORK_DIR="${REPO_ROOT}/tmp/trust-limit-demo"
RESULTS_DIR="${REPO_ROOT}/presentation/assets/demos/trust-limit"
RESULTS_FILE="${RESULTS_DIR}/results.tsv"
ERRORS_DIR="${RESULTS_DIR}/errors"
PROVIDER_LIST_FILE="${WORK_DIR}/providers.txt"

mkdir -p "${WORK_DIR}" "${RESULTS_DIR}" "${ERRORS_DIR}"

# ---- helpers ----
log()  { printf '\033[36m[demo]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

provider_id_for() {
  # i=1 -> DEMO00000000000000000000000000-1, 2 -> -2, ...
  # 단, IAM은 OIDC URL의 id 부분에 hyphen+숫자도 허용 (자유 문자열)
  local i="$1"
  printf '%s%02d' "${PROVIDER_ID_PREFIX}" "${i}"
}

provider_url_for() {
  local i="$1"
  printf 'oidc.eks.%s.amazonaws.com/id/%s' "${REGION}" "$(provider_id_for "${i}")"
}

provider_arn_for() {
  local account_id="$1"
  local i="$2"
  printf 'arn:aws:iam::%s:oidc-provider/%s' "${account_id}" "$(provider_url_for "${i}")"
}

build_trust_policy() {
  # $1: account_id, $2: count(N) — 1..N 까지 OIDC provider를 trust 에 포함
  local account_id="$1"
  local count="$2"
  local statements=()
  for i in $(seq 1 "${count}"); do
    local url
    url="$(provider_url_for "${i}")"
    statements+=("$(cat <<EOF
{
  "Effect": "Allow",
  "Principal": {
    "Federated": "arn:aws:iam::${account_id}:oidc-provider/${url}"
  },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "${url}:aud": "${AUDIENCE}",
      "${url}:sub": "${SERVICE_ACCOUNT_SUB}"
    }
  }
}
EOF
)")
  done
  local joined
  joined="$(IFS=,; echo "${statements[*]}")"
  printf '{"Version":"2012-10-17","Statement":[%s]}' "${joined}"
}

# ---- subcommands ----
cmd_preflight() {
  require aws
  require jq
  local ident
  ident="$(aws sts get-caller-identity --output json)"
  local account_id arn
  account_id="$(echo "${ident}" | jq -r '.Account')"
  arn="$(echo "${ident}" | jq -r '.Arn')"
  log "AWS account : ${account_id}"
  log "Caller ARN  : ${arn}"
  log "Region      : ${REGION}"
  log "Role name   : ${ROLE_NAME}"
  log "Target count: ${TARGET_COUNT}"
  echo
  read -r -p "이 계정/리전에서 진행할까요? (yes/no) " ans
  [[ "${ans}" == "yes" ]] || die "aborted"
  echo "${account_id}" > "${WORK_DIR}/account.txt"
}

cmd_provision() {
  require aws
  require jq
  [[ -f "${WORK_DIR}/account.txt" ]] || die "preflight 먼저 실행하세요"
  local account_id
  account_id="$(cat "${WORK_DIR}/account.txt")"

  : > "${PROVIDER_LIST_FILE}"
  for i in $(seq 1 "${TARGET_COUNT}"); do
    local url arn
    url="$(provider_url_for "${i}")"
    arn="$(provider_arn_for "${account_id}" "${i}")"

    if aws iam get-open-id-connect-provider \
        --open-id-connect-provider-arn "${arn}" >/dev/null 2>&1; then
      log "[${i}/${TARGET_COUNT}] already exists: ${arn}"
    else
      log "[${i}/${TARGET_COUNT}] creating: https://${url}"
      if ! aws iam create-open-id-connect-provider \
            --url "https://${url}" \
            --client-id-list "${AUDIENCE}" \
            --thumbprint-list "${THUMBPRINT}" \
            --output json >/dev/null 2> "${WORK_DIR}/provision-${i}.err"; then
        warn "create-open-id-connect-provider 실패 (i=${i}). 메시지:"
        cat "${WORK_DIR}/provision-${i}.err" >&2
        die "fake OIDC URL 등록이 거부됐습니다. 대안: 실 EKS 클러스터 OIDC URL 사용 또는 thumbprint 변경 후 재시도."
      fi
    fi
    echo "${arn}" >> "${PROVIDER_LIST_FILE}"
  done
  log "총 $(wc -l < "${PROVIDER_LIST_FILE}" | tr -d ' ')개 provider 준비 완료"
}

cmd_run() {
  require aws
  require jq
  [[ -f "${WORK_DIR}/account.txt" ]] || die "preflight 먼저 실행하세요"
  local account_id
  account_id="$(cat "${WORK_DIR}/account.txt")"

  # 초기 Role: 빈 policy 로 만들 수 없으니 entry 1개로 시작
  local initial_policy
  initial_policy="$(build_trust_policy "${account_id}" 1)"
  if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
    log "Role 이미 존재: ${ROLE_NAME} (trust 갱신만 진행)"
    aws iam update-assume-role-policy \
      --role-name "${ROLE_NAME}" \
      --policy-document "${initial_policy}" >/dev/null
  else
    log "Role 생성: ${ROLE_NAME}"
    aws iam create-role \
      --role-name "${ROLE_NAME}" \
      --description "AWS KRUG 2026 IRSA trust policy size limit demo" \
      --assume-role-policy-document "${initial_policy}" \
      --output json >/dev/null
  fi

  printf 'count\tlength\tstatus\terror_code\n' > "${RESULTS_FILE}"

  for n in $(seq 1 "${TARGET_COUNT}"); do
    local policy length err_file http_code status err_code
    policy="$(build_trust_policy "${account_id}" "${n}")"
    length="$(printf '%s' "${policy}" | wc -c | tr -d ' ')"
    err_file="${ERRORS_DIR}/n-$(printf '%02d' "${n}").err"

    if aws iam update-assume-role-policy \
          --role-name "${ROLE_NAME}" \
          --policy-document "${policy}" 2> "${err_file}"; then
      status="OK"
      err_code=""
      log "[N=${n}] length=${length} -> OK"
    else
      status="FAIL"
      err_code="$(grep -oE 'An error occurred \([^)]+\)' "${err_file}" | head -1 | sed -E 's/^An error occurred \(//; s/\)$//')"
      [[ -z "${err_code}" ]] && err_code="(unknown)"
      log "[N=${n}] length=${length} -> FAIL (${err_code})"
      log "       full error -> ${err_file}"
    fi
    printf '%d\t%d\t%s\t%s\n' "${n}" "${length}" "${status}" "${err_code}" >> "${RESULTS_FILE}"

    if [[ "${status}" == "FAIL" ]]; then
      log "한도에 도달했습니다. 결과: ${RESULTS_FILE}"
      break
    fi
  done

  echo
  log "=== summary (${RESULTS_FILE}) ==="
  column -t -s $'\t' "${RESULTS_FILE}"
}

cmd_cleanup() {
  require aws
  log "Role 삭제: ${ROLE_NAME}"
  if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
    # attached policy 가 없는 전제 (이 데모는 trust 만 다룸)
    aws iam delete-role --role-name "${ROLE_NAME}" || warn "Role 삭제 실패 — attached policy/instance profile 확인"
  else
    log "Role 없음, skip"
  fi

  if [[ -f "${PROVIDER_LIST_FILE}" ]]; then
    while IFS= read -r arn; do
      [[ -z "${arn}" ]] && continue
      log "OIDC provider 삭제: ${arn}"
      aws iam delete-open-id-connect-provider \
        --open-id-connect-provider-arn "${arn}" 2>/dev/null \
        || warn "삭제 실패: ${arn}"
    done < "${PROVIDER_LIST_FILE}"
  else
    warn "${PROVIDER_LIST_FILE} 없음. 이름 prefix(${PROVIDER_ID_PREFIX})로 수동 삭제 필요할 수 있음"
  fi
}

usage() {
  cat <<USAGE
Usage: $(basename "$0") {preflight|provision|run|all|cleanup}

  preflight  AWS 계정/리전 확인 후 진행 컨펌
  provision  fake OIDC provider ${TARGET_COUNT}개 등록
  run        Role 생성 후 trust entry 를 1..N 까지 늘려가며 한도 측정
  all        preflight -> provision -> run 일괄 실행
  cleanup    Role 및 OIDC provider 정리

env override: REGION, ROLE_NAME, TARGET_COUNT, AUDIENCE, THUMBPRINT
USAGE
}

case "${1:-help}" in
  preflight) cmd_preflight ;;
  provision) cmd_provision ;;
  run)       cmd_run ;;
  all)       cmd_preflight; cmd_provision; cmd_run ;;
  cleanup)   cmd_cleanup ;;
  help|*)    usage ;;
esac
