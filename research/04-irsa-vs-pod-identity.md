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

### CloudTrail 로깅 차이: IRSA vs Pod Identity

- **IRSA**: Pod가 `AssumeRoleWithWebIdentity`를 STS에 직접 호출 → CloudTrail에 `eventSource: sts.amazonaws.com`, `eventName: AssumeRoleWithWebIdentity`, `userIdentity.type: WebIdentityUser`로 기록됨. `userIdentity.identityProvider`에 OIDC provider ARN이 포함되므로 어느 클러스터/IdP에서 온 요청인지 식별 가능.[^iam-cloudtrail]
  - OIDC 이벤트의 `additionalEventData.identityProviderConnectionVerificationMethod` 필드는 AWS가 OIDC IdP 연결을 검증한 방법을 나타내며 `IAMTrustStore` 또는 `Thumbprint` 값을 가진다.[^iam-cloudtrail]
- **Pod Identity**: EKS Pod Identity Agent가 EKS Auth API의 `AssumeRoleForPodIdentity` 액션을 호출 → CloudTrail에 `eventSource: eks-auth.amazonaws.com`, `eventName: AssumeRoleForPodIdentity`로 기록됨 (STS `AssumeRoleWithWebIdentity` 이벤트 없음).[^pi-auth-api]
- Pod Identity 공식 문서는 감사 가능성(Auditability)을 명시적 이점으로 나열한다: "Access and event logging is available through AWS CloudTrail to help facilitate retrospective auditing."[^pod-id-overview]
- **Blue/green trust 갱신 누락과 CloudTrail 추적 어려움**: IRSA에서 trust policy에 새 OIDC provider가 없으면 STS는 `InvalidIdentityToken` 에러를 반환한다. CloudTrail은 "some non-authenticated AWS STS requests might not be logged because they do not meet the minimum expectation of being sufficiently valid to be trusted as a legitimate request"라고 명시하므로, `InvalidIdentityToken` 계열 에러는 CloudTrail에 남지 않아 운영자가 실패 원인을 추적하기 어렵다.[^iam-cloudtrail]

### IRSA 에러 타입별 CloudTrail 로깅 여부

trust policy 갱신 누락 또는 OIDC 설정 오류 시 발생하는 에러 중 일부는 CloudTrail에 남지 않는다.[^iam-cloudtrail][^repost-oidc-fed]

| 에러 | 원인 | CloudTrail 로깅 여부 |
|---|---|---|
| `InvalidIdentityToken: No OpenIDConnect provider found` | trust policy에 해당 OIDC issuer 없음 (blue/green 갱신 누락 포함) | ❌ 누락 (client-side 분류) |
| `InvalidIdentityToken: Incorrect token audience` | OIDC token의 aud claim 불일치 | ❌ 누락 (client-side 분류) |
| `AccessDenied: Not authorized to perform sts:AssumeRoleWithWebIdentity` | sub/aud claim이 trust condition과 불일치 (인증은 통과) | ✅ 로깅됨 |

근거: cloudtrail-integration.html은 "some non-authenticated AWS STS requests might not be logged because they do not meet the minimum expectation of being sufficiently valid to be trusted as a legitimate request"라고 명시. `InvalidIdentityToken: No OpenIDConnect provider found`는 이 조건에 해당해 CloudTrail에 기록되지 않는다.[^iam-cloudtrail]

Pod Identity는 노드 IAM Role로 인증된 요청이므로 이 사각지대가 존재하지 않는다 ("logs all authenticated API requests").[^iam-cloudtrail]

[^iam-cloudtrail]: https://docs.aws.amazon.com/IAM/latest/UserGuide/cloudtrail-integration.html
[^pi-auth-api]: https://docs.aws.amazon.com/eks/latest/APIReference/API_auth_AssumeRoleForPodIdentity.html
[^pod-id-overview]: https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html
[^repost-oidc-fed]: https://repost.aws/knowledge-center/iam-oidc-idp-federation
