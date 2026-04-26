# 04 — IRSA vs Pod Identity 비교

## 요약 (3줄)
- TBD: 양쪽의 보안 모델·운영 부담·확장성 한 장으로 정리.
- TBD: IRSA가 더 적합한 케이스 / Pod Identity가 더 적합한 케이스.
- TBD: 두 방식이 공존 가능한지, 마이그레이션 시 점진적으로 갈아탈 수 있는지.

## 비교 항목 (초안)

| 항목 | IRSA | Pod Identity |
|---|---|---|
| 신뢰 메커니즘 | OIDC IdP (클러스터별 issuer) | EKS 내부 Agent + STS API |
| Role 연결 | ServiceAccount annotation + Role trust policy 양쪽 | Pod Identity Association (1곳) |
| 멀티클러스터 trust 갱신 | 클러스터마다 trust relationship 별도 관리 | Association은 클러스터 로컬, trust 불필요 |
| Token 갱신 | projected token rotation | Agent가 자격증명 캐시·갱신 |
| 의존 컴포넌트 | OIDC IdP (한 번 설정) | Pod Identity Agent (DaemonSet 상시 동작) |
| 설정 위치 | IAM (Role trust) + K8s (SA annotation) | EKS API (Association) |
| 지원 SDK | 광범위 (`AWS_WEB_IDENTITY_TOKEN_FILE`) | SDK 최소 버전 요구 |

## 미해결 질문 (확인 필요)
- [ ] Pod Identity가 cross-account role assume를 지원하는가? (IRSA는 가능)
- [ ] 같은 Pod에서 두 방식을 동시 사용 가능한가?
- [ ] IRSA의 OIDC token을 외부에 사용 가능 (EKS 외 워크로드에서 STS 호출)? Pod Identity는?

## Findings
<!-- 사실 + footnote URL을 누적. -->
