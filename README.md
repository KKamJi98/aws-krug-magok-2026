# EKS Pod Identity로 더 간편하게 Kubernetes 서비스 권한 관리하기

AWS Korea User Group 마곡 DevOps 소모임 (2026-04-28) 발표 자료입니다.

## 발표 정보

| 항목 | 내용 |
|---|---|
| 일시 | 2026-04-28(화) 19:00 ~ |
| 장소 | AWS Korea User Group 마곡 DevOps 소모임 |
| 발표자 | 김태지 (Ethan, 번개장터 DevSecOps Engineer) |
| 분량 | 30분 |
| 이벤트 링크 | https://www.meetup.com/awskrug/events/314064008/ |

## 슬라이드

- **PDF**: [`presentation/slides.pdf`](presentation/slides.pdf) — 31장, 발표용 최종본
- **Markdown 원본**: [`presentation/slides.md`](presentation/slides.md) — Marp 소스
- **테마**: [`presentation/theme.css`](presentation/theme.css)

## 발표 흐름 (30분)

| # | 섹션 | 슬라이드 # | 핵심 메시지 |
|---|---|---|---|
| 1–2 | 자기소개 + 목차 | 1–2 | — |
| 3 | Pod의 AWS 인증 + credential provider chain | 3–9 | Java v2 / Boto3 / JS v3 / Go v2 — 4개 SDK 모두 IRSA(web identity) > Pod Identity(container) |
| 4 | IRSA vs Pod Identity 구조 비교 | 10–12 | 신뢰의 출발점이 OIDC issuer(per-cluster) → service principal(universal)로 이동 |
| 5 | 멀티클러스터 IRSA 운영 함정 | 13–16 | trust policy 길이 한도, blue/green 갱신 누락, CloudTrail 사각지대 |
| 6 | Pod Identity로 어떻게 해소되는가 | 17–20 | trust 한 줄 + ABAC session tag 6종 |
| 7 | Pod Identity 동작 상세 | 21–25 | Agent → EKS Auth API `AssumeRoleForPodIdentity` → STS는 EKS service가 호출 |
| 8 | 전환 시 운영 편의성 | 26–28 | chain precedence가 안전망 — association 먼저, annotation 나중 |
| 9–10 | 정리 + Q&A | 29–31 | "결합점이 per-cluster에서 per-service로" |

## 자료 구조

```
.
├── presentation/
│   ├── slides.pdf                # 발표 최종 PDF (31장)
│   ├── slides.md                 # Marp 원본
│   ├── theme.css                 # 커스텀 테마
│   ├── assets/diagrams/          # HTML 다이어그램 source + webp 산출물
│   │   ├── 01-credential-chain.html       # Java v2 6단계
│   │   ├── 01b-credential-chain-python.html  # Boto3 12단계 중 핵심 6단계
│   │   ├── 01c-credential-chain-js.html   # JavaScript v3 7단계
│   │   ├── 01d-credential-chain-go.html   # Go v2 4단계
│   │   ├── 02-irsa-flow.html              # IRSA 동작 흐름
│   │   ├── 03-pod-identity-flow.html      # Pod Identity 동작 흐름
│   │   ├── 04-irsa-vs-pi-comparison.html  # IRSA vs Pod Identity 5축 비교
│   │   └── 05-multi-cluster-pitfalls.html # trust policy 길이 벽
│   └── assets/demos/             # 라이브 실험 evidence (results.tsv, error logs, screenshots)
│       └── trust-limit/          # IRSA trust policy 2048자 한도 데모 결과
├── research/                     # 섹션별 리서치 노트 (출처 footnote 포함)
│   ├── 00-outline.md             # 전체 outline + 시간 배분
│   ├── 01-credential-provider-chain.md
│   ├── 02-irsa-architecture.md
│   ├── 03-pod-identity-architecture.md
│   ├── 04-irsa-vs-pod-identity.md
│   ├── 05-multi-cluster-irsa-pitfalls.md
│   └── 06-pod-identity-migration.md
├── scripts/
│   ├── build-slides.sh                   # Marp PDF 빌드
│   ├── render-diagrams.{js,sh}           # HTML 다이어그램 → webp 렌더
│   ├── irsa-trust-limit-demo.sh          # AWS CLI 기반 trust 한도 데모
│   └── terraform-trust-limit-demo/       # Terraform 기반 동일 데모
├── references.md                 # 인용한 AWS 공식 문서 / SDK / GitHub URL 카탈로그
└── Makefile                      # 빌드/데모 진입점
```

## 인용 출처

모든 사실 주장에는 footnote URL을 붙였습니다. 카테고리별 카탈로그는 [`references.md`](references.md)를 참고해 주세요.

핵심 출처:
- [AWS — IAM and AWS STS quotas](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_iam-quotas.html) — trust policy 2,048자/8,192자, OIDC provider 100/700개 quota
- [AWS — EKS Pod Identity overview](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
- [AWS — IAM roles for service accounts (IRSA)](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- [AWS — EKS Best Practices: Identity and Access Management](https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html)
- [AWS Blog — Amazon EKS Pod Identity launch](https://aws.amazon.com/blogs/containers/amazon-eks-pod-identity-a-new-way-for-applications-on-eks-to-obtain-iam-credentials/)
- [aws/eks-pod-identity-agent (GitHub)](https://github.com/aws/eks-pod-identity-agent)

## 빌드 (재현용)

```bash
# 의존성 설치 (1회)
make install

# HTML 다이어그램 → webp
make diagrams

# 슬라이드 PDF 빌드
make slides

# Marp 라이브 미리보기
make watch
```

필수:
- Node 18+
- `playwright` Chromium (`npx playwright install chromium`)
- `sharp` (npm 의존성에 포함)

## IRSA trust policy 한도 데모 (라이브 실험)

발표 섹션 5(멀티클러스터 IRSA 함정)의 **"trust policy 길이의 벽"** 주장을 직접 재현하는 스크립트입니다. 개인 AWS 계정에 fake OIDC provider 12개를 등록하고 한 IAM Role 의 trust statement 를 1개씩 늘려가며 한도(default 2,048자) 도달 시점의 실제 에러 메시지를 캡처합니다.

```bash
# 1) 계정/리전 확인 (interactive 컨펌)
make demo-trust-preflight

# 2) fake OIDC provider 12개 등록 (~10초, 무료)
make demo-trust-provision

# 3) Role 생성 + trust 1..N 점진 시도 → 한도에서 LimitExceeded 발생
make demo-trust-run
make demo-trust-show          # results.tsv 표 출력

# 4) Terraform 동일 시나리오 (provision 으로 등록한 OIDC provider 재사용)
make demo-trust-tf-init
make demo-trust-tf-apply  TRUST_COUNT=4   # OK
make demo-trust-tf-apply  TRUST_COUNT=5   # FAIL: ACLSizePerRole 2048
make demo-trust-tf-capture TRUST_COUNT=5  # 출력을 errors/tf-N5.log 로 저장

# 5) 정리
make demo-trust-tf-destroy
make demo-trust-cleanup
```

**필수**: AWS CLI v2, `jq`, (Terraform 1.5+ 데모만), 자격증명이 가리키는 계정에서 IAM Role / OIDC provider create/delete 권한.

**산출물**: `presentation/assets/demos/trust-limit/`
- `results.tsv` — entry 수 / 정규화 길이 / 성공·실패 / 에러 코드
- `errors/n-NN.err` — bash 데모 stderr 원문
- `errors/tf-N*.log` — Terraform apply 출력 캡처

전체 옵션은 `make help` 참고.

## 라이선스

본 저장소의 발표 콘텐츠(슬라이드·다이어그램·리서치·레퍼런스)는 [**CC BY 4.0**](https://creativecommons.org/licenses/by/4.0/)으로 배포됩니다 — 출처를 표시하시면 자유롭게 공유·각색·재배포 가능합니다. 자세한 내용은 [`LICENSE`](LICENSE) 참고.

인용된 AWS 공식 문서, 블로그, GitHub 코드의 권리는 각 권리자에게 있으며, 모든 인용에 출처 URL이 명시되어 있습니다.

## 연락

질문 / 오류 신고: GitHub Issues 또는 발표 후 직접 문의해 주세요.
