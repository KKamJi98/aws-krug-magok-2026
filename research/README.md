# research/

발표 섹션별 리서치 노트. 모든 사실 주장은 footnote URL 부착 (CLAUDE.md §1).

## 인덱스

| 파일 | 섹션 # | 주제 | 다이어그램 |
|---|---|---|---|
| `00-outline.md` | — | 전체 흐름 + 시간 배분 | — |
| `01-credential-provider-chain.md` | 3 | AWS SDK credential provider chain | 01-credential-chain |
| `02-irsa-architecture.md` | 4 | IRSA 동작 원리 (OIDC, STS AssumeRoleWithWebIdentity) | 02-irsa-flow |
| `03-pod-identity-architecture.md` | 4, 7 | Pod Identity 동작 원리 (Agent, Association, AssumeRoleForPodIdentity) | 03-pod-identity-flow |
| `04-irsa-vs-pod-identity.md` | 4, 6 | 두 방식 비교 (UX, 보안 모델, 운영 부담) | 04-irsa-vs-pi-comparison |
| `05-multi-cluster-irsa-pitfalls.md` | 5 | 멀티클러스터·블루그린 IRSA 운영 함정 | 05-multi-cluster-pitfalls |
| `06-pod-identity-migration.md` | 8 | IRSA → Pod Identity 전환 시나리오 + 운영 편의 | — |

## 작성 규칙

- 각 파일 상단에 **요약 (3줄)** + **미해결 질문** 섹션
- 사실은 출처 footnote 필수
- 추측은 "Inferred:" prefix
- 번개장터 사례는 일반화 명칭 (cluster-blue/green, role-app-name)
