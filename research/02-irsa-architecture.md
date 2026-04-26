# 02 — IRSA Architecture

## 요약 (3줄)
- IRSA = (1) 클러스터별 OIDC issuer + IAM OIDC provider, (2) Pod Identity Webhook이 SA annotation 보고 `AWS_ROLE_ARN`+`AWS_WEB_IDENTITY_TOKEN_FILE`+projected volume 주입, (3) SDK가 STS `AssumeRoleWithWebIdentity` 직접 호출. **STS quota를 customer 계정이 소모**.
- Trust policy는 OIDC provider ARN을 `Principal.Federated`로 두고 `aud=sts.amazonaws.com` + `sub=system:serviceaccount:<ns>:<sa>` 조건. `StringEquals`(권장) vs `StringLike`(보안 ↓). Trust policy 길이 제한 2048/8192자 → 한 Role에 묶을 수 있는 trust 관계는 보통 ~4-8개 (멀티클러스터 단점 슬라이드 핵심 근거).
- Token: kubelet이 TTL 80%/24h 중 더 빠른 시점에 refresh, BoundSAToken 기본 1h, EKS는 최대 90일 grace 후 거부.

## 미해결 질문 (확인 필요)
- [x] EKS OIDC issuer URL은 클러스터 단위 고유한가? → 그렇다 (per-cluster, 7일 signing key rotation). 재생성 시 ID 변경은 best-practices 문서가 강하게 시사하나 명시적 기술 미발견(Inferred). Findings §OIDC issuer
- [x] ServiceAccount projected token rotation 주기 → kubelet refresh = TTL 80% 또는 24h 중 빠른 쪽. BoundSAToken 1h 기본, EKS 최대 90일 grace. Findings §Projected token rotation
- [x] EKS Pod Identity Webhook은 어떻게 처리하는가? → `eks.amazonaws.com/role-arn` annotation 보고 `AWS_ROLE_ARN`+`AWS_WEB_IDENTITY_TOKEN_FILE` env + projected volume 주입. Findings §Pod Identity Webhook injection
- [x] Trust `StringEquals` vs `StringLike` trade-off → AWS 공식: `StringEquals` 권장. `StringLike`는 wildcard 허용 → boundary 약화. Findings §Trust policy structure
- [ ] 클러스터 재생성 시 OIDC issuer ID가 다른지 명시적으로 확인 (현재 Inferred). 후속: EKS API Reference `cluster.identity.oidc.issuer` lifecycle, IRSA launch blog.

## Findings
<!-- 사실 + footnote URL을 누적. -->

### OIDC issuer (cluster-unique)

- 각 EKS 클러스터에는 자체 OIDC issuer URL이 연결되어 있으며, AWS CLI `aws eks describe-cluster --query 'cluster.identity.oidc.issuer'`로 조회한다. 형식은 `https://oidc.eks.<region>.amazonaws.com/id/<UNIQUE_ID>`.[^oidc-fetch-keys]
- IRSA를 사용하려면 클러스터의 OIDC issuer URL에 대해 IAM OIDC provider가 별도로 생성되어야 한다 (per-cluster). IAM의 기본 글로벌 quota는 계정당 100 OIDC providers (최대 700까지 증액 가능).[^iam-quotas][^service-accounts-irsa-vs-pi]
- Amazon EKS는 클러스터별로 public OIDC discovery endpoint를 호스팅하며, signing key는 7일마다 자동 회전한다. EKS는 만료될 때까지 이전 public key를 유지한다.[^irsa-tech-overview]
- OIDC discovery endpoint 호출은 EKS가 throttle하므로 외부에서 검증하는 경우 `cache-control` header를 존중하여 JWKS를 캐시해야 한다.[^oidc-fetch-keys]
- Inferred (AWS 공식 문서에서 명시 못 찾음, 검증 필요): 클러스터 재생성 시 OIDC issuer ID가 동일한지는 공식 문서에 직접 명시된 부분을 찾지 못함. 단 best practices 문서의 "blue/green cluster upgrade 시 각 IRSA role의 trust policy를 새 클러스터의 OIDC endpoint로 update해야 한다"는 기술은 신규 클러스터마다 새 issuer URL이 발급됨을 강하게 시사한다.[^irsa-blue-green]

### Projected token rotation

- EKS Pod Identity Webhook은 `kubelet`이 ServiceAccount projected token을 발급·refresh하도록 Pod에 projected volume을 주입한다. 기본 마운트 경로는 `/var/run/secrets/eks.amazonaws.com/serviceaccount/token`이며 Pod의 `AWS_WEB_IDENTITY_TOKEN_FILE` 환경변수가 이 경로를 가리킨다.[^pod-config]
- `kubelet`은 token TTL의 80%가 경과했거나 token이 24시간보다 오래된 경우 (둘 중 더 빠른 시점) 자동으로 token을 refresh한다. 기본 service account가 아닌 SA의 경우 PodSpec의 projected volume `expirationSeconds`로 만료 기간을 조정할 수 있다.[^pod-config]
- Kubernetes의 `BoundServiceAccountTokenVolume` 기능은 audience·time·key bound JWT를 발급한다. 기본 만료는 1시간이며, EKS 클러스터에서는 client SDK가 즉시 refresh하지 못하는 경우를 대비해 최대 90일까지 grace 기간이 적용된다 (90일 초과 token은 API server가 거부).[^k8s-sa-tokens]
- EKS API server는 1시간 이상 된 token으로 들어온 요청에 대해 audit log에 `annotations.authentication.k8s.io/stale-token` annotation을 남긴다. CloudWatch Logs Insights로 stale token Pod를 식별할 수 있다.[^k8s-sa-tokens]

### Pod Identity Webhook injection

- EKS Pod Identity Webhook은 `eks.amazonaws.com/role-arn: arn:aws:iam::<account-id>:role/<role-name>` annotation이 있는 ServiceAccount를 사용하는 Pod를 mutating admission webhook으로 감시한다.[^pod-config]
- 매칭되는 Pod에 다음을 자동 주입한다:[^pod-config]
  - 환경변수 `AWS_ROLE_ARN` (ServiceAccount annotation의 role ARN)
  - 환경변수 `AWS_WEB_IDENTITY_TOKEN_FILE` (projected token 파일 경로, 예: `/var/run/secrets/eks.amazonaws.com/serviceaccount/token`)
  - projected ServiceAccount token volume 마운트
- Webhook은 강제가 아니다. SDK가 환경변수를 직접 읽을 수만 있으면 webhook 없이 Pod spec에 수동으로 같은 변수·volume을 정의해도 IRSA가 동작한다.[^pod-config]
- 지원 버전의 AWS SDK는 default credential provider chain에서 web identity token 환경변수를 우선 탐색하여 STS `AssumeRoleWithWebIdentity`를 호출한다.[^pod-config]

### Trust policy structure

- IRSA role의 trust policy는 `Action: sts:AssumeRoleWithWebIdentity` + `Principal.Federated`에 OIDC provider ARN을 지정해야 한다. 형식: `arn:aws:iam::<account-id>:oidc-provider/oidc.eks.<region>.amazonaws.com/id/<OIDC_ID>`.[^associate-sa-role]
- `Condition`은 두 claim을 검증한다 (AWS 공식 예시 그대로):[^associate-sa-role]
  - `<oidc-provider>:aud` = `sts.amazonaws.com` (audience claim)
  - `<oidc-provider>:sub` = `system:serviceaccount:<namespace>:<service-account-name>` (subject claim)
- IAM OIDC provider 생성 시 audience는 `sts.amazonaws.com`으로 등록한다.[^enable-irsa]
- `StringEquals` vs `StringLike` trade-off:
  - `StringEquals`: 정확한 namespace + ServiceAccount 이름만 매칭. AWS 공식 권장 (best practices: "make the role trust policy as explicit as possible by including the service account name").[^irsa-bp-scope]
  - `StringLike`: namespace 또는 SA 이름에 wildcard(`*`)를 허용. 예: `system:serviceaccount:<namespace>:*`로 namespace 내 모든 SA 허용. 같은 namespace 내 다른 Pod도 role을 assume 가능하므로 boundary가 약해진다. AWS 공식 문서는 "여러 SA·namespace를 허용하려면 `StringEquals`에 항목을 여러 개 추가하거나 `StringLike`로 변경하라"고 안내하면서도, best practices에서는 SA name까지 명시(`StringEquals`)하는 방식을 권장한다.[^associate-sa-role][^irsa-bp-scope]
- Role trust policy 길이 제한은 기본 2048자, 증액해도 8192자 한도. 일반적으로 단일 trust policy당 4개의 trust 관계 (증액 시 최대 8개) 정도가 들어간다.[^iam-quotas][^service-accounts-irsa-vs-pi]

### STS quota & throttling

- IRSA는 SDK가 Pod 내부에서 직접 STS `AssumeRoleWithWebIdentity`를 호출한다. 새 SDK session을 만들 때마다 STS 호출이 발생한다.[^irsa-bp-reuse-session]
- AWS STS request quota는 기본 600 requests/sec, account·region 단위. `AssumeRole`, `GetCallerIdentity`, `GetSessionToken` 등이 같은 quota를 공유한다 (`AssumeRoleWithWebIdentity`는 AWS credentials를 사용하지 않으므로 별도 quota이지만, 호출 폭증 시 throttle 가능).[^iam-quotas]
- AWS 공식 권장: SDK session을 재사용하여 `AssumeRoleWithWebIdentity` 호출 빈도를 줄인다. boto3 등에서 한 번 생성한 session으로 여러 service client를 만들면 SDK가 만료 시점에 자동으로 credentials를 refresh한다.[^irsa-bp-reuse-session]
- 비교: EKS Pod Identity는 SDK가 STS를 직접 호출하지 않고 EKS Auth API (`AssumeRoleForPodIdentity`)를 통해 EKS service가 role assumption을 수행하므로, customer 계정의 STS quota를 소비하지 않는다.[^service-accounts-irsa-vs-pi]
- EC2 / EKS service principal이 service 내부적으로 호출하는 STS request는 customer 계정의 STS RPS quota에 포함되지 않는다.[^iam-quotas]
- `AssumeRoleWithWebIdentity`로 발급된 임시 credential의 기본 session duration은 1시간. `DurationSeconds` 파라미터로 15분(900s)부터 role의 max session duration (1~12시간)까지 설정 가능.[^sts-assumerole-webidentity]

[^irsa-tech-overview]: https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html
[^oidc-fetch-keys]: https://docs.aws.amazon.com/eks/latest/userguide/irsa-fetch-keys.html
[^iam-quotas]: https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_iam-quotas.html
[^service-accounts-irsa-vs-pi]: https://docs.aws.amazon.com/eks/latest/userguide/service-accounts.html
[^pod-config]: https://docs.aws.amazon.com/eks/latest/userguide/pod-configuration.html
[^k8s-sa-tokens]: https://docs.aws.amazon.com/eks/latest/userguide/service-accounts.html
[^associate-sa-role]: https://docs.aws.amazon.com/eks/latest/userguide/associate-service-account-role.html
[^enable-irsa]: https://docs.aws.amazon.com/eks/latest/userguide/enable-iam-roles-for-service-accounts.html
[^irsa-bp-scope]: https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html
[^irsa-bp-reuse-session]: https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html
[^irsa-blue-green]: https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html
[^sts-assumerole-webidentity]: https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRoleWithWebIdentity.html
