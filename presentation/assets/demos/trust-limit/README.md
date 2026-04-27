# IRSA trust policy 길이 한도 데모 (evidence)

발표 섹션 5 — **"단일 Role + 합친 trust = trust policy 길이의 벽"** 주장의 실측 evidence.

## 결론 한 줄

세 경로(AWS CLI / Console / Terraform) 모두 동일한 IAM 측 한도에서 동일한 에러 코드로 실패한다 — **`LimitExceeded: Cannot exceed quota for ACLSizePerRole: 2048`**.

## 실험 setup

| 항목 | 값 |
|---|---|
| 계정 quota | default (`Role trust policy length` = 2048자, 증액 미신청) |
| 리전 | `ap-northeast-2` |
| 한 entry 형태 | `Federated` + `aud` + `sub` (슬라이드와 동일) |
| 한 entry 정규화 길이 | ~520자 (compact JSON 기준 ~520, IAM normalize 후 ~410) |
| OIDC provider | fake 12개 (`oidc.eks.<region>.amazonaws.com/id/DEMO0000...01..12`) |

## bash CLI 결과 — `results.tsv`

| count | length(chars) | status | error_code |
|---|---|---|---|
| 1 | 557 | OK | |
| 2 | 1076 | OK | |
| 3 | 1595 | OK | |
| 4 | 2114 | OK | |
| 5 | 2633 | **FAIL** | `LimitExceeded` |

원문 stderr — `errors/n-05.err`:

```text
aws: [ERROR]: An error occurred (LimitExceeded) when calling the
UpdateAssumeRolePolicy operation: Cannot exceed quota for ACLSizePerRole: 2048
```

흥미 포인트: 4개 entry 시 우리 측 compact JSON 길이는 **2114자(>2048)** 였지만 IAM 은 OK 처리. IAM 이 whitespace/key ordering 을 normalize 한 뒤 측정한다는 시사점.

## Console 결과 — `screenshots/console-acl-size-per-role.png`

IAM 콘솔에서 동일 trust policy 를 붙여 넣고 저장 시도한 화면. 빨간 배지로 `Failed to update trust policy. Cannot exceed quota for ACLSizePerRole: 2048` 표시.

## Terraform 결과 — `errors/tf-N5.log`

Terraform AWS provider 5.x 의 `aws_iam_role` 리소스에서 동일 시나리오. Plan 단계에서는 `~ 1 to change` 로 정상 표시되지만 apply 시 IAM API 가 reject:

```text
Error: updating IAM Role (role-trust-limit-demo-tf) assume role policy:
operation error IAM: UpdateAssumeRolePolicy, https response error
StatusCode: 409, RequestID: <uuid>,
LimitExceeded: Cannot exceed quota for ACLSizePerRole: 2048
```

(account ID 는 `123456789012` 로 마스킹됨. 원본은 `tf-N5.log.raw` 로 로컬 보존, gitignored.)

## 재현 방법

상세 명령은 repo root `README.md` 의 "IRSA trust policy 한도 데모" 섹션 참조. 핵심:

```bash
# AWS CLI 데모
make demo-trust-preflight
make demo-trust-provision
make demo-trust-run
make demo-trust-show

# Terraform 데모 (provider 재사용)
make demo-trust-tf-init
make demo-trust-tf-apply  TRUST_COUNT=4   # OK (length normalize 후 ≤2048)
make demo-trust-tf-capture TRUST_COUNT=5  # FAIL, errors/tf-N5.log 갱신

# 정리
make demo-trust-tf-destroy
make demo-trust-cleanup
```

## 출처 (관련 슬라이드 인용 근거)

- [IAM and AWS STS quotas — Role trust policy length](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_iam-quotas.html) — default 2,048자, 자동 승인 max 8,192자
- [Amazon EKS Pod Identity launch blog](https://aws.amazon.com/blogs/containers/amazon-eks-pod-identity-a-new-way-for-applications-on-eks-to-obtain-iam-credentials/) — *"default 2048 → typically 4 trust relationships, max 8192 → typically 8"*
- [EKS Best Practices — Identity and Access Management](https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html) — blue/green 클러스터 업그레이드 시 trust 갱신 부담
