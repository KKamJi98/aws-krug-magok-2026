# 00 — Outline

발표 전체 흐름 + 슬라이드/다이어그램 매핑.

## 시간 배분 (총 30분)

| # | 섹션 | 슬라이드 # | 다이어그램 | 시간(분) | 누적 |
|---|---|---|---|---|---|
| 1 | 자기소개 | 1 | — | 1 | 1 |
| 2 | 목차 | 2 | — | 1 | 2 |
| 3 | Pod의 AWS 인증 방법 + credential provider chain | 3–9 | 01·01b·01c·01d-credential-chain | 5 | 7 |
| 4 | IRSA vs Pod Identity 구조 비교 | 10–12 | 02-irsa-flow, 03-pod-identity-flow, 04-irsa-vs-pi-comparison | 5 | 12 |
| 5 | 멀티클러스터 IRSA 운영 함정 (NARRATIVE CORE) | 13–16 | 05-multi-cluster-pitfalls + arn-example/arn-pair 인라인 | 6 | 18 |
| 6 | Pod Identity로 어떻게 해소하는가 | 17–20 | (04-comparison 재활용) | 4 | 22 |
| 7 | Pod Identity 아키텍처/동작 상세 | 21–25 | 03-pod-identity-flow 확장 | 4 | 26 |
| 8 | 전환 시 운영 편의성 | 26–28 | — | 2 | 28 |
| 9 | 정리 | 29–30 | — | 1 | 29 |
| 10 | 마무리 + Q&A 안내 | 31 | — | 1 | 30 |

> **Section 5 hook 정리 (2026-04-27)**: "그런데 왜 IRSA를 멀티클러스터에서 쓰면 곤란한가?" 슬라이드(=현 13번)는 Section 4의 마무리가 아니라 **Section 5의 hook**으로 분류. 구조 비교(10–12)는 5축 비교로 끝나고, 13번부터 OIDC ARN 분해 → Blue/Green 장애 시나리오 → trust policy 길이 벽 → CloudTrail 사각지대까지 한 섹션에 묶임.
>
> **slide.md 라인 매핑** (실측 2026-04-27): 1=title, 2=목차(L29), 3=Pod 인증(L50), 4=Java v2(L63), 5=Boto3(L77), 6=JS v3(L91), 7=Go v2(L105), 8=First Match Wins(L119), 9=같은 Pod 둘 다(L133), 10=IRSA 구조(L153), 11=PI 구조(L168), 12=한 장 비교(L184), 13=왜 IRSA 곤란(L197), 14=Blue/Green(L221), 15=trust policy 길이의 벽(L246), 16=CloudTrail 없다(L260), 17=PI의 답(L278), 18=PI trust policy(L297), 19=ABAC tag(L318), 20=Cross-account quota(L332), 21=PI 동작 7-step(L352), 22=Agent 동작(L365), 23=AssumeRoleForPodIdentity(L377), 24=Association(L393), 25=Network/Proxy(L405), 26=운영 부담 4가지(L423), 27=마이그레이션 단계(L436), 28=솔직한 한계(L452), 29=take-away 5가지(L470), 30=한 장 결론(L484), 31=Q&A.

## 핵심 메시지 (3줄 요약)

1. **인증 단계가 길어질수록 운영 부담이 커진다** — credential provider chain을 이해해야 IRSA·Pod Identity의 차이가 보인다.
2. **IRSA는 멀티클러스터·블루그린에서 OIDC trust relationship 갱신 부담이 누적된다** — 클러스터 갱신 시 trusted entities를 까먹으면 장애.
3. **Pod Identity는 association을 클러스터 단위로 관리해 trust relationship 자체를 제거한다** — 운영 단순화.

## 청중 가정

- AWS Korea User Group DevOps 소모임 멤버
- EKS·IAM 기본 개념은 이해한다고 가정
- IRSA를 한 번이라도 운영해본 사람 비중 높을 것으로 예상
- 멀티클러스터를 실제로 운영해본 사람은 소수

## 톤

- 운영자 관점 (이론보다 실제 부담·복구 시나리오 중심)
- 단정적 사실 vs 추론은 명확히 구분
- AWS 공식 문서 footnote로 신뢰성 확보
