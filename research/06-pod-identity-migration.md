# 06 — IRSA → Pod Identity 전환 시나리오 + 운영 편의성

## 요약 (3줄)
- TBD: 전환 단계 (점진적 마이그레이션 vs 일괄 교체).
- TBD: 전환 후 사라지는 운영 부담 (OIDC trust 관리, 클러스터 교체 시 trust 갱신, Role 네이밍 충돌).
- TBD: 전환 시 주의할 점 (SDK 버전, cross-account 한계, Agent 의존성).

## 전환 체크리스트 (초안)

- [ ] EKS 클러스터에 Pod Identity Agent 설치 (Add-on)
- [ ] 대상 ServiceAccount의 IAM Role을 Pod Identity Association으로 등록
- [ ] Role의 trust policy에 `pods.eks.amazonaws.com` 추가 (또는 새 Role 생성)
- [ ] 워크로드 재시작으로 새 자격증명 획득
- [ ] 검증: Pod 안에서 `aws sts get-caller-identity` 결과 확인
- [ ] IRSA annotation (`eks.amazonaws.com/role-arn`) 제거
- [ ] OIDC trust relationship에서 ServiceAccount subject 제거 (필요 시)

## 운영 편의성 (발표용 핵심)

| 운영 항목 | IRSA | Pod Identity |
|---|---|---|
| 클러스터 추가 시 IAM Role 작업 | OIDC trust 갱신 | 없음 (Association만) |
| Role 네이밍 일관성 | 클러스터별 prefix 필요 | 단일 Role 재사용 가능 |
| 블루그린 교체 | OIDC trust 양쪽 관리 | 새 클러스터에서 Association만 다시 |
| trust 누락 사고 | 빈번 | 구조적으로 발생 안 함 |

## 미해결 질문 (확인 필요)
- [ ] Add-on 버전별 호환성 (EKS 1.27+ ?)
- [ ] cross-account 시나리오에서 IRSA 유지가 필요한가?
- [ ] 점진 마이그레이션 시 같은 Role을 IRSA + Pod Identity 양쪽으로 trust 가능한가?

## Findings
<!-- 사실 + footnote URL을 누적. -->
