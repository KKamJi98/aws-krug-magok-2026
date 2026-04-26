# References

본 발표에 인용된 외부 자료 카탈로그. **dedupe append**, 중복 URL 방지하며 추가만.

각 항목 포맷: `- [Title](URL) — 한 줄 메모`

---

## AWS 공식 문서

<!-- Pod Identity, IRSA, IAM, STS, EKS 관련 docs.aws.amazon.com URL -->
- [Grant Kubernetes workloads access to AWS using Kubernetes Service Accounts](https://docs.aws.amazon.com/eks/latest/userguide/service-accounts.html) — IRSA vs EKS Pod Identity 공식 비교 (role/cluster/STS 쿼터 등)
- [EKS Pod Identity overview](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html) — Pod Identity 핵심 개요·지원 환경·association 한도·proxy 주의
- [Understand how EKS Pod Identity works](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-how-it-works.html) — Pod Identity 동작 흐름, 주입 env (`AWS_CONTAINER_CREDENTIALS_FULL_URI`, `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE`), chain precedence 원칙
- [Set up the Amazon EKS Pod Identity Agent](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-agent-setup.html) — agent DaemonSet, loopback `169.254.170.23` / `[fd00:ec2::23]`, 노드 role 권한
- [AssumeRoleForPodIdentity API](https://docs.aws.amazon.com/eks/latest/APIReference/API_auth_AssumeRoleForPodIdentity.html) — Pod Identity Agent가 호출하는 EKS Auth API
- [EKS Best Practices — Identity and Access Management](https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html) — IRSA vs Pod Identity, IMDSv2 hop limit 권장(2), aws-node IRSA 전환
- [EKS Auto Mode managed instances](https://docs.aws.amazon.com/eks/latest/userguide/automode-learn-instances.html) — Auto Mode IMDSv2 hop limit=1 강제
- [IAM roles for service accounts](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html) — IRSA technical overview, OIDC IdP 배경, signing key 7일 회전
- [Fetch signing keys to validate OIDC tokens](https://docs.aws.amazon.com/eks/latest/userguide/irsa-fetch-keys.html) — 클러스터별 OIDC issuer URL 형식, JWKS 캐시·throttle 권고
- [Configure Pods to use a Kubernetes service account](https://docs.aws.amazon.com/eks/latest/userguide/pod-configuration.html) — Pod Identity Webhook injection (`AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE`), kubelet token 80%/24h refresh
- [Assign IAM roles to Kubernetes service accounts](https://docs.aws.amazon.com/eks/latest/userguide/associate-service-account-role.html) — IRSA trust policy 표준 구조 (`sub`/`aud` claim, `StringEquals`/`StringLike`)
- [Create an IAM OIDC provider for your cluster](https://docs.aws.amazon.com/eks/latest/userguide/enable-iam-roles-for-service-accounts.html) — OIDC provider 등록 audience=`sts.amazonaws.com`
- [IAM and AWS STS quotas](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_iam-quotas.html) — STS 기본 600 RPS quota, role trust policy 2048→8192자, OIDC providers 100→700개
- [AssumeRoleWithWebIdentity API](https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRoleWithWebIdentity.html) — IRSA가 호출하는 STS API, session duration 기본 1h (15분~12h)
- [Assign an IAM role to a Kubernetes service account](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-association.html) — Pod Identity Association 생성 절차 (Console/CLI), trust policy 검증
- [Create IAM role with trust policy required by EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-role.html) — Pod Identity 표준 trust policy 형태, namespace/SA Condition 예시
- [Grant Pods access to AWS resources based on tags (Pod Identity ABAC)](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-abac.html) — 자동 session tag 6종, transitive cross-account 동작, `disableSessionTags` 사용 시점
- [Use pod identity with the AWS SDK](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-minimum-sdk.html) — Pod Identity 지원 SDK 최소 버전 매트릭스
- [Configure Pods to access AWS services with service accounts](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-configure-pods.html) — Pod 배포 후 env 검증 절차 (`AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE`)
- [CreatePodIdentityAssociation API](https://docs.aws.amazon.com/eks/latest/APIReference/API_CreatePodIdentityAssociation.html) — association 입력 필드 (cluster/namespace/SA/roleArn/targetRoleArn/policy/disableSessionTags)
- [PodIdentityAssociation data type](https://docs.aws.amazon.com/eks/latest/APIReference/API_PodIdentityAssociation.html) — association 응답 구조, `externalId`로 cross-account confused-deputy 방지
- [Access Amazon EKS using AWS PrivateLink](https://docs.aws.amazon.com/eks/latest/userguide/vpc-interface-endpoints.html) — `com.amazonaws.<region>.eks-auth` interface endpoint, private cluster 요건
- [Amazon EKS add-ons](https://docs.aws.amazon.com/eks/latest/userguide/eks-add-ons.html) — Pod Identity Agent add-on 설치 경로(Console/CLI/eksctl/CFN), Auto Mode 사전 설치
- [Update existing cluster to new Kubernetes version](https://docs.aws.amazon.com/eks/latest/userguide/update-cluster.html) — in-place control plane upgrade 흐름 (OIDC issuer 보존 근거 — blue/green 대비 문구)
- [Logging IAM and AWS STS API calls with AWS CloudTrail](https://docs.aws.amazon.com/IAM/latest/UserGuide/cloudtrail-integration.html) — STS 인증/비인증 요청 로깅 정책. "some non-authenticated AWS STS requests might not be logged because they do not meet the minimum expectation of being sufficiently valid to be trusted as a legitimate request" — `InvalidIdentityToken` 계열이 CloudTrail에 안 남는 primary 근거
- [AWS Identity and Access Management endpoints and quotas](https://docs.aws.amazon.com/general/latest/gr/iam-service.html) — IAM 서비스 쿼터 공식 테이블 (Role trust policy length L-C07B4B0D default 2,048자 조정 가능, Roles per account L-FE177D64 default 1,000)
- [EKS Best Practices — Known Limits and Service Quotas](https://docs.aws.amazon.com/eks/latest/best-practices/known_limits_and_service_quotas.html) — EKS 운영 시 닿는 IAM/VPC/ELB 쿼터 목록. IRSA 관련 trust policy 길이·OIDC provider 수·Role 수 쿼터를 "Impact" 컬럼과 함께 명시
- [Set up IAM runtime role for EMR on EKS](https://docs.aws.amazon.com/emr/latest/EMR-on-EKS-DevelopmentGuide/setting-up-enable-IAM.html) — "maximum of twelve EKS clusters due to the 4096 character limit" — IRSA trust policy 길이 제약의 타 서비스 실사례 인용 근거

## AWS SDK

<!-- credential provider chain 문서 (Java, Go, Python 등) -->
- [Default credentials provider chain — AWS SDK for Java 2.x](https://docs.aws.amazon.com/sdk-for-java/latest/developer-guide/credentials-chain.html) — Java v2 6단계 체인 순서 (system props → env → web identity → profile → container → instance profile)
- [AWS SDKs and Tools — Standardized credential providers](https://docs.aws.amazon.com/sdkref/latest/guide/standardized-credentials.html) — 모든 SDK 공통 credential provider 카테고리 정의 (cross-SDK normative)
- [Container credential provider — AWS SDKs and Tools Reference](https://docs.aws.amazon.com/sdkref/latest/guide/feature-container-credentials.html) — `AWS_CONTAINER_CREDENTIALS_FULL_URI`, `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE` 표준 정의 + SDK 지원 매트릭스
- [Configure the SDK — AWS SDK for Go v2](https://docs.aws.amazon.com/sdk-for-go/v2/developer-guide/configure-gosdk.html) — Go v2 default credential chain 순서
- [Credentials — Boto3](https://docs.aws.amazon.com/boto3/latest/guide/credentials.html) — boto3 12단계 credential 탐색 순서
- [Set credentials in Node.js — AWS SDK for JavaScript v3](https://docs.aws.amazon.com/sdk-for-javascript/v3/developer-guide/setting-credentials-node.html) — Node.js v3 default chain 순서 (env→SSO→ini→web identity→container→IMDS)
- [HttpCredentialsProvider.Builder — AWS SDK for Java 2.x javadoc](https://docs.aws.amazon.com/java/api/latest/software/amazon/awssdk/auth/credentials/HttpCredentialsProvider.Builder.html) — `asyncCredentialUpdateEnabled` 옵션 (Java v2 default = sync refresh)
- [Configuring IMDS hop limit — EC2 User Guide](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-IMDS-existing-instances.html) — IMDS `httpPutResponseHopLimit` 의미와 기본값

## AWS GitHub 소스

<!-- aws/eks-pod-identity-agent 등 AWS-official open-source 저장소. commit pin 권장. -->
- [aws/eks-pod-identity-agent — repo root](https://github.com/aws/eks-pod-identity-agent) — Pod Identity Agent 공식 오픈소스
- [cmd/server.go — `LoadDefaultConfig` 호출 + 서버 플래그](https://github.com/aws/eks-pod-identity-agent/blob/d4dc0f3fedd795b26ac88755238867a2110c7460/cmd/server.go) — agent가 Go SDK v2 default chain으로 부트스트랩
- [charts/.../templates/daemonset.yaml](https://github.com/aws/eks-pod-identity-agent/blob/d4dc0f3fedd795b26ac88755238867a2110c7460/charts/eks-pod-identity-agent/templates/daemonset.yaml) — `hostNetwork: true`, probe 타이밍, `priorityClassName`
- [charts/.../values.yaml](https://github.com/aws/eks-pod-identity-agent/blob/d4dc0f3fedd795b26ac88755238867a2110c7460/charts/eks-pod-identity-agent/values.yaml) — Helm default values, hybrid daemonset 정의
- [internal/credsretriever/refreshing_cache.go](https://github.com/aws/eks-pod-identity-agent/blob/d4dc0f3fedd795b26ac88755238867a2110c7460/internal/credsretriever/refreshing_cache.go) — agent 측 LRU cache, `defaultMinCredentialTtl=15s`, recoverable retry
- [internal/cloud/eksauth/service.go](https://github.com/aws/eks-pod-identity-agent/blob/d4dc0f3fedd795b26ac88755238867a2110c7460/internal/cloud/eksauth/service.go) — EKS Auth 호출 socket=500ms / total=1000ms timeout
- [internal/cloud/eksauth/errors.go](https://github.com/aws/eks-pod-identity-agent/blob/d4dc0f3fedd795b26ac88755238867a2110c7460/internal/cloud/eksauth/errors.go) — `IsIrrecoverableApiError` recoverable/irrecoverable 분류
- [internal/sharedcredsrotater/rotating_shared_credentials_provider.go](https://github.com/aws/eks-pod-identity-agent/blob/d4dc0f3fedd795b26ac88755238867a2110c7460/internal/sharedcredsrotater/rotating_shared_credentials_provider.go) — Hybrid Nodes용 1분 회전 shared credentials provider
- [README.md](https://github.com/aws/eks-pod-identity-agent/blob/d4dc0f3fedd795b26ac88755238867a2110c7460/README.md) — agent 동작 모델 설명

## AWS 블로그

<!-- launch announcement, deep dive 등 -->
- [Amazon EKS Pod Identity: a new way for applications on EKS to obtain IAM credentials](https://aws.amazon.com/blogs/containers/amazon-eks-pod-identity-a-new-way-for-applications-on-eks-to-obtain-iam-credentials/) — Pod Identity launch blog (2023-12-28). IRSA 멀티클러스터 한계(trust policy 길이 2048→8192, 보통 4~8 trust, OIDC provider per-account quota), Pod Identity 비교표, 마이그레이션 dual-trust 패턴

## CNCF / Kubernetes 문서

<!-- ServiceAccount, projected token 등 -->

## 보조 자료 (블로그·SO 등)

<!-- 검증된 보조 자료. 가능하면 공식 문서로 교체할 것. -->
- [Troubleshoot IRSA errors in Amazon EKS (re:Post)](https://repost.aws/knowledge-center/eks-troubleshoot-irsa-errors) — `InvalidIdentityToken: No OpenIDConnect provider found`, audience mismatch, thumbprint, AccessDenied 정확한 에러 문자열
- [Resolve OIDC IdP federation errors in IAM (re:Post)](https://repost.aws/knowledge-center/iam-oidc-idp-federation) — STS `InvalidIdentityToken` 계열 모든 변형. CloudTrail이 `InvalidIdentityToken`을 로깅 안 함 (client-side 실패) 명시
- [Troubleshoot IAM "Not authorized to perform AssumeRoleWithWebIdentity" (re:Post)](https://repost.aws/knowledge-center/iam-idp-access-error) — trust policy mismatch 시 `AccessDenied` + CloudTrail PrincipalId 비교 절차
