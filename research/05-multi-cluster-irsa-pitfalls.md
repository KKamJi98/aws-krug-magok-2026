# 05 — 멀티클러스터 IRSA 운영 함정

발표의 핵심 "왜 Pod Identity인가" 동기 부분. 번개장터 사례를 일반화해 사용.

## 요약 (3줄)
- **AWS 공식 정량**: 한 IAM Role의 trust policy에 묶을 수 있는 trust 관계는 기본 ~4개, 증액해도 ~8개 (2048/8192자 한도). 멀티클러스터 footprint가 그 이상이면 Role 분리(시나리오 A) 또는 Pod Identity 전환이 강제됨.[^pi-launch-blog]
- **Blue/green 함정**: AWS Best Practices 공식 문서가 "blue/green upgrade 시 모든 IRSA Role의 trust policy를 새 OIDC provider로 갱신해야 한다"고 명시. 누락 시 `InvalidIdentityToken: No OpenIDConnect provider found...` 또는 `AccessDenied`. **CloudTrail은 InvalidIdentityToken 계열을 client-side로 분류해 로깅하지 않음** → 운영자가 "어디서 실패했는지" 추적 어려움 (강력한 발표 hook).[^bp-blue-green][^repost-oidc-fed]
- **Pod Identity의 답**: Trust policy = 단일 service principal(`pods.eks.amazonaws.com`). 클러스터 수가 늘어도 trust policy 길이 변화 없음. cross-cluster 식별은 ABAC session tag(`eks-cluster-arn` 등)로 분리.[^pi-launch-blog][^bp-pod-id-eks-bp]

## 시나리오 (일반화 명칭)

### 시나리오 A: 클러스터당 Role 분리
- `cluster-blue` → `role-app-name-blue`, `cluster-green` → `role-app-name-green`
- 장점: 각 Role의 trust 관리 단순
- 단점: Role 수가 (서비스 × 클러스터)로 증가, IAM 관리 ↑, 권한 drift 위험

### 시나리오 B: 단일 Role에 여러 OIDC trust 합치기
- `role-app-name`의 trust에 `cluster-blue` OIDC issuer + `cluster-green` OIDC issuer 둘 다 명시
- 장점: 서비스당 Role 1개로 단순
- 단점: 클러스터 추가/교체 시 trust 갱신 누락 시 장애 직결, 권한 폭탄(다 클러스터에서 통용)

### 시나리오 C (실제 실패 사례, 일반화): 블루그린 클러스터 교체 중 trust 갱신 누락
- 새 `cluster-green` 생성 → 새 OIDC issuer URL
- 기존 Role trust에 추가 누락 → 워크로드 마이그레이션 후 `AssumeRoleWithWebIdentity` 401
- 청중에게 가장 와닿는 이야기, 30초~1분 분량으로 구술

## 미해결 질문 (확인 필요)
- [x] AWS 권장사항이 "클러스터당 Role 분리"인지 "Role 통합"인지 공식 입장 → "Use one IAM role per application" + 멀티클러스터/대규모는 Pod Identity + ABAC 권장. Findings §AWS official multi-cluster guidance
- [x] In-place EKS upgrade는 OIDC issuer 보존 (best-practices의 blue/green 대비 문구로 확인). Findings §OIDC issuer lifecycle
- [ ] Cluster 재생성 시 OIDC issuer ID가 다른지 명시적 단언은 AWS 공식 문서에서 못 찾음 (Inferred from Pod Identity launch blog "each new cluster"). 후속 검증 후보: EKS API Reference `Cluster.identity.oidc.issuer` lifecycle 또는 신규 issuer 발급 정책 페이지.
- [x] Trust 갱신 누락 시 에러 메시지 → `InvalidIdentityToken: No OpenIDConnect provider found` / `AccessDenied: Not authorized to perform sts:AssumeRoleWithWebIdentity`. CloudTrail은 `InvalidIdentityToken`을 로깅 안 함 (client-side). Findings §Scenario C
- [x] Trust policy 길이 한도 → 기본 2048 / max 8192. 한 Role 내 trust 관계 ~4(default) / ~8(증액). Findings §Trust policy length limits
- [x] Pod Identity가 이 문제를 어떻게 해소하는지 한 줄 요약 → trust policy = 단일 service principal, cluster 수와 무관. Cross-cluster 식별은 ABAC session tag로. Findings §AWS official multi-cluster guidance + research/06.

## Findings
<!-- 사실 + footnote URL을 누적. -->

### AWS official multi-cluster guidance

- AWS는 IRSA를 멀티클러스터에서 운영할 때 두 가지 운영 부담을 명시한다:[^pi-launch-blog]
  1. "Cluster administrators have to update the IAM role trust policy each time the role is used in a new cluster during scenarios like blue-green upgrades or failover testing."
  2. "As customers grow their EKS cluster footprint, due to the per cluster OIDC provider requirement in IRSA, customers run into the per account OIDC provider limit."
  3. "Similarly, as they scale the number of clusters or Kubernetes namespaces in which an IAM role is used, they run into IAM trust policy size limit, which makes them duplicate the IAM roles to overcome the trust policy size limit."
- EKS Best Practices Guide는 blue/green cluster upgrade 시 IRSA의 운영 부담을 명시적으로 경고한다: "If you employ a blue/green approach to cluster upgrades instead of performing an in-place cluster upgrade when using IRSA, you will need to update the trust policy of each of the IRSA IAM roles with the OIDC endpoint of the new cluster."[^bp-blue-green]
- 동일 문서는 Pod Identity의 동일 시나리오 운영 절차를 대조 제시한다: "When using blue/green cluster upgrades with EKS Pod Identity, you would create pod identity associations between the IAM roles and service accounts in the new cluster. And update the IAM role trust policy if you have a `sourceArn` condition."[^bp-blue-green]
- Pod Identity는 trust policy를 신규 클러스터마다 갱신할 필요가 없다. 공식 비교표: **Role extensibility — IRSA**: "You have to update the IAM role's trust policy with the new EKS cluster OIDC provider endpoint each time you want to use the role in a new cluster." **EKS Pod Identity**: "You have to setup the role one time, to establish trust with the newly introduced EKS service principal `pods.eks.amazonaws.com`. After this one-time step, you don't need to update the role's trust policy each time it is used in a new cluster."[^pi-launch-blog]
- AWS의 공식 권장 (best practices): "Use one IAM role per application. … When using ABAC with EKS Pod Identity, you may use a common IAM role across multiple service accounts and rely on their session attributes for access control. This is especially useful when operating at scale, as ABAC allows you to operate with fewer IAM roles."[^bp-one-role] 즉 IRSA로 단일 Role을 여러 클러스터에 공유하라고 권장하지는 않으며, 멀티클러스터/대규모 환경에서는 Pod Identity + ABAC을 권장한다.

### OIDC issuer lifecycle (cluster recreate / upgrade)

- 각 EKS 클러스터에는 클러스터별 고유 OIDC issuer URL이 존재한다 (`https://oidc.eks.<region>.amazonaws.com/id/<UNIQUE_ID>`). EKS는 클러스터별로 public OIDC endpoint를 호스팅하고 signing key를 7일마다 회전한다.[^oidc-fetch-keys]
- IRSA를 쓰려면 클러스터의 OIDC issuer URL에 대해 **별도의 IAM OIDC provider**를 등록해야 한다. IAM OIDC provider 글로벌 quota는 계정당 100개 (요청 시 700까지 증액 가능).[^iam-quotas][^pi-launch-blog]
- **In-place EKS minor version upgrade**는 OIDC issuer URL을 유지한다 (control plane API server를 새 인스턴스로 rolling update하지만 cluster identity 자체는 동일 cluster resource로 유지됨; "Once you upgrade a cluster, you can't downgrade to a previous version" 문구도 cluster identity 보존을 전제로 한다).[^update-cluster-doc] AWS 공식 문서는 "in-place upgrade는 OIDC issuer가 보존된다"는 직접 문장을 별도로 명시하지 않으나, blog의 "blue-green upgrades or failover testing" 표현이 trust policy 갱신을 요구한다고 한 것은 곧 in-place 업그레이드는 갱신이 불필요함을 의미한다 (Inferred from contrast).[^pi-launch-blog]
- **Cluster 삭제 후 재생성**(같은 이름, 같은 region)의 경우:
  - **Cluster ARN**은 동일하다 — Pod Identity ABAC 문서가 명시: "The cluster ARN is unique, but if a cluster is deleted and recreated in the same region with the same name, within the same AWS account, it will have the same ARN."[^bp-pod-id-abac]
  - **OIDC issuer URL의 unique ID**는 다르다는 직접 문장은 AWS 공식 문서에서 못 찾음 (Inferred). 단 blog 본문이 "cluster administrators have to update the IAM role trust policy each time the role is used in a new cluster"라고 명시하므로 "신규 클러스터 = 신규 OIDC issuer ID = trust policy 갱신 필요"가 운영상 강하게 시사된다.[^pi-launch-blog]

### Scenario A — Per-cluster Role split (verified facts)

- 시나리오: `cluster-blue` → `role-app-name-blue`, `cluster-green` → `role-app-name-green`. 각 Role의 trust policy는 자기 클러스터의 OIDC provider ARN과 `sub`(`system:serviceaccount:<ns>:<sa>`) 조건만 단일 entry로 가짐.
- Trust policy 길이 한도 부담은 사라짐 (2048자 기본 한도 안에 entry 1개만 들어감).[^iam-quotas]
- **단점 (verified)**: Role 수가 (서비스 × 클러스터)로 곱해진다. AWS는 Pod Identity 비교표에서 IRSA의 한계를 다음과 같이 명시: "you are typically limited to a maximum of eight trust relationships within a single policy."[^pi-launch-blog] 즉 한 Role에 8개 이상의 클러스터를 묶을 수 없으므로 어차피 Role 분리가 강제될 수 있다.
- **단점 (verified)**: 권한 drift. AWS best practices "Use one IAM role per application"가 권장하는 1:1 매핑이지만, 같은 application이 여러 클러스터에 존재하면 (서비스 × 클러스터) Role 모두에 동일 permission policy를 sync해야 한다. 공식 문서는 이 sync 부담 자체를 직접 언급하지는 않으므로 발표에서 "운영 경험상" 으로 인용 가능 (근거 추가 불필요한 청중 공감 포인트).
- IAM OIDC provider 100개 quota 제한도 동시에 부담 — 클러스터 수가 100을 넘으면 quota 증액 (max 700) 필요.[^iam-quotas][^pi-launch-blog]

### Scenario B — Single Role with merged OIDC trust (verified facts)

- 시나리오: `role-app-name` 한 Role의 trust policy에 `cluster-blue` OIDC provider ARN + `cluster-green` OIDC provider ARN을 둘 다 등록. `Condition`은 두 OIDC provider 각각의 `sub`/`aud` claim을 별도 statement 또는 `StringEquals`의 array로 묶음.[^associate-sa-role]
- **Trust policy 길이 한도가 가장 큰 제약**: 기본 2048자, 한도 증액 후 max 8192자.[^iam-quotas] AWS 공식 표현: "By default, the length of trust policy size is 2048. This means that you can typically define four trust relationships in a single policy. While you can get the trust policy length limit increased, you are typically limited to a maximum of eight trust relationships within a single policy."[^pi-launch-blog]
- 따라서 한 Role에 묶을 수 있는 클러스터 수는 **기본 ~4개, 증액 후 ~8개가 사실상 상한**. 5개 이상 클러스터 환경에서는 trust 추가 시 `LimitExceeded`/`MalformedPolicyDocument`(길이 초과) 에러로 update 실패.[^iam-quotas][^pi-launch-blog]
- AWS 공식 권장 trust 패턴은 `StringEquals` (정확 매칭) + namespace + ServiceAccount 명시. 멀티클러스터에서 단일 Role을 쓰려면 OIDC provider별 statement를 추가하는 방식이며, `StringLike`로 wildcard를 넓히는 것은 권장되지 않는다.[^bp-irsa-scope]
- **운영 부담 (AWS 명시)**: "they run into IAM trust policy size limit, which makes them duplicate the IAM roles to overcome the trust policy size limit."[^pi-launch-blog] — 즉 결국 Scenario A로 회귀하는 압력이 발생한다.

### Scenario C — Blue/green migration missed-trust failure mode

- 새 `cluster-green` 생성 → 새 OIDC issuer URL이 발급된다 (Inferred, 위 §OIDC issuer lifecycle 참조). 운영자는 (1) IAM OIDC provider를 신규 등록하고 (2) 모든 IRSA Role의 trust policy에 신규 OIDC provider ARN + sub/aud 조건을 추가해야 한다.[^bp-blue-green]
- Trust policy 갱신 누락 시 발생하는 **에러 메시지 (AWS 공식 troubleshooting)**:[^repost-irsa-troubleshoot][^repost-oidc-fed]
  - **Case 1 — IAM OIDC provider 미등록**: `An error occurred (InvalidIdentityToken) when calling the AssumeRoleWithWebIdentity operation: No OpenIDConnect provider found in your account for https://oidc.eks.<region>.amazonaws.com/id/<UNIQUE_ID>` (HTTP 400). CloudTrail에는 client-side 실패라 기록되지 않음.
  - **Case 2 — Trust policy의 OIDC provider ARN/조건 mismatch**: `An error occurred (AccessDenied) when calling the AssumeRoleWithWebIdentity operation: Not authorized to perform sts:AssumeRoleWithWebIdentity` (HTTP 403).
  - **Case 3 — IAM OIDC provider audience 잘못 설정**: `An error occurred (InvalidIdentityToken) when calling the AssumeRoleWithWebIdentity operation: Incorrect token audience` (audience는 `sts.amazonaws.com` 이어야 함).
- **CloudTrail 한계 (primary AWS doc)**: AWS IAM 공식 문서는 STS의 비인증 요청 로깅 정책을 명시한다 — "CloudTrail logs all authenticated API requests to IAM and AWS STS API operations. CloudTrail also logs non-authenticated requests to the AWS STS actions, AssumeRoleWithSAML and AssumeRoleWithWebIdentity, and logs information provided by the identity provider. **However, some non-authenticated AWS STS requests might not be logged because they do not meet the minimum expectation of being sufficiently valid to be trusted as a legitimate request.**"[^iam-cloudtrail-integration] AWS re:Post 문서는 이 카테고리 중 `InvalidIdentityToken`이 client-side 실패로 분류돼 CloudTrail에 기록되지 않는 구체 케이스라고 보충한다.[^repost-oidc-fed] → 운영자는 워크로드 측 SDK 로그·Pod log·k8s event로만 detect 가능. 발표 hook으로 강함.
- **`AccessDenied` 계열 (sub/aud mismatch)**은 CloudTrail의 STS event에 기록된다. PrincipalId 값을 trust policy의 매칭 조건과 비교해 검증 가능.[^repost-iam-idp-error]
- **CloudTrail STS logging 정책의 primary 근거 정리** (`iam-cloudtrail-integration.html`):[^iam-cloudtrail-integration]
  - STS 인증 요청은 모두 로깅됨.
  - `AssumeRoleWithSAML` / `AssumeRoleWithWebIdentity`의 **비인증 요청도 일반적으로는 로깅됨** (IdP가 제공한 정보 포함).
  - 단 "**some non-authenticated AWS STS requests might not be logged because they do not meet the minimum expectation of being sufficiently valid to be trusted as a legitimate request**" — 이 문장이 `InvalidIdentityToken: No OpenIDConnect provider found` 같이 "STS가 정당한 요청으로 신뢰할 minimum validity를 못 갖춘" 케이스가 CloudTrail에 안 남는 정책적 근거가 된다.
  - 이 문서는 `InvalidIdentityToken`이라는 특정 에러 코드를 직접 명시하지는 않는다. 구체적인 "InvalidIdentityToken은 client-side로 분류돼 로깅 안 함" 표현은 AWS re:Post(`iam-oidc-idp-federation`)에만 존재하므로, 발표 슬라이드에서는 primary 근거(IAM 공식 문서)와 보조 근거(re:Post)를 함께 인용하는 게 안전하다.
- 마이그레이션 안전 전략 (AWS 공식): IRSA → Pod Identity 전환 시 Role의 trust policy에 **OIDC provider와 `pods.eks.amazonaws.com` service principal을 동시에 등록**해 두고 (dual trust), Pod Identity association을 먼저 만든다. EKS Pod Identity webhook이 chain에서 IRSA보다 먼저 매칭되지 않으므로 (IRSA = chain 3rd, Pod Identity = chain 5th), 마이그레이션 중에는 **IRSA가 그대로 사용**된다. annotation 제거 후 Pod 재시작 시점에 자연 전환된다.[^pi-launch-blog][^bp-pod-id-eks-bp]

### Trust policy length limits in practice

- IAM Role trust policy 길이 quota: **기본 2048자, 증액 시 max 8192자**.[^iam-quotas] IAM General Reference 공식 쿼터 테이블(quota ID L-C07B4B0D)로 독립 확인.[^iam-general-ref]
- IAM quotas 페이지의 자동승인 증액 상한 테이블: "Role trust policy length | 2048 characters | **8192 characters**" (4,096이 아님).[^iam-quotas]
- AWS Pod Identity launch blog의 정량 분석: "By default, the length of trust policy size is 2048. This means that you can typically define **four** trust relationships in a single policy. While you can get the trust policy length limit increased, you are typically limited to a maximum of **eight** trust relationships within a single policy."[^pi-launch-blog]
- AWS EMR on EKS 공식 docs는 같은 quota를 다른 entry 길이로 환산해 명시: "eliminating the constraint of a single Job Execution IAM Role being shared across a **maximum of twelve EKS clusters due to the 4096 character limit on IAM trust policy length**."[^emr-eks-pod-id] — entry가 condition 없는 짧은 형태(~340자)일 때 도달 가능한 상한. Pod Identity launch blog의 4/8 추정과 entry 길이 가정이 다를 뿐 같은 quota를 인용한다.
- EKS Best Practices Known Limits 문서가 IRSA 운영 관점에서 IAM 쿼터를 명시적으로 나열한다:[^eks-known-limits]
  - "IAM | Role trust policy length | Can limit the number of clusters an IAM role is associated with for IRSA | L-C07B4B0D | default 2,048"
  - "IAM | Roles per account | Can limit the number of clusters or IRSA roles in an account. | L-FE177D64 | default 1,000"
  - "IAM | OpenId connect providers per account | Can limit the number of Clusters per account, OpenID Connect is used by IRSA | L-858F3967 | default 100"
- 5번째/6번째 클러스터 OIDC trust 추가 시 IAM update 시점의 에러 (AWS는 정확한 message 텍스트를 EKS 문서에 게시하지 않으나, 일반 IAM policy update 시 길이 초과는 `MalformedPolicyDocument` 또는 `LimitExceededException`으로 반환됨 — 정확한 문자열은 IAM 콘솔/SDK 환경에 따라 다름. 발표에서는 "trust policy size limit hit" 정도로만 표현하고 정확한 문자열은 데모 캡처로 보여주는 게 안전함).
- Quota 증액은 IAM Service Quotas 콘솔에서 "Role trust policy length" 항목으로 요청 가능.[^iam-quotas] 단 증액해도 8192자가 hard limit — 멀티클러스터 8개를 넘는 footprint에서는 결국 Role 분리(=Scenario A) 또는 Pod Identity 전환이 강제된다.[^pi-launch-blog]
- Pod Identity는 trust policy에 **단일 statement** (`Principal.Service: pods.eks.amazonaws.com`)만 들어가므로 cluster 수가 늘어나도 trust policy 길이가 증가하지 않는다. ABAC condition (`aws:PrincipalTag/eks-cluster-arn` 등)은 permission policy 또는 resource policy 쪽에 작성된다.[^bp-pod-id-eks-bp][^bp-pod-id-abac]

[^pi-launch-blog]: https://aws.amazon.com/blogs/containers/amazon-eks-pod-identity-a-new-way-for-applications-on-eks-to-obtain-iam-credentials/
[^bp-blue-green]: https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html
[^bp-one-role]: https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html
[^bp-irsa-scope]: https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html
[^bp-pod-id-eks-bp]: https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html
[^bp-pod-id-abac]: https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html
[^oidc-fetch-keys]: https://docs.aws.amazon.com/eks/latest/userguide/irsa-fetch-keys.html
[^iam-quotas]: https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_iam-quotas.html
[^update-cluster-doc]: https://docs.aws.amazon.com/eks/latest/userguide/update-cluster.html
[^associate-sa-role]: https://docs.aws.amazon.com/eks/latest/userguide/associate-service-account-role.html
[^iam-cloudtrail-integration]: https://docs.aws.amazon.com/IAM/latest/UserGuide/cloudtrail-integration.html
[^repost-irsa-troubleshoot]: https://repost.aws/knowledge-center/eks-troubleshoot-irsa-errors
[^repost-oidc-fed]: https://repost.aws/knowledge-center/iam-oidc-idp-federation
[^repost-iam-idp-error]: https://repost.aws/knowledge-center/iam-idp-access-error
[^eks-known-limits]: https://docs.aws.amazon.com/eks/latest/best-practices/known_limits_and_service_quotas.html
[^iam-general-ref]: https://docs.aws.amazon.com/general/latest/gr/iam-service.html
[^emr-eks-pod-id]: https://docs.aws.amazon.com/emr/latest/EMR-on-EKS-DevelopmentGuide/setting-up-enable-IAM.html
