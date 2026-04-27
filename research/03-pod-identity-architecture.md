# 03 — Pod Identity Architecture

## 요약 (3줄)
- 구성: 노드 DaemonSet인 Pod Identity Agent(loopback `169.254.170.23`) + 클러스터별 `CreatePodIdentityAssociation`(unique key = cluster + namespace + serviceAccount). SDK는 표준 container credential provider slot에서 `AssumeRoleForPodIdentity`를 호출해 임시 credential 수신.
- **Trust policy의 Principal은 항상 `pods.eks.amazonaws.com` 단일 service principal** — OIDC/account ID에 결합되지 않아 **모든 클러스터·계정에 같은 trust policy 재사용 가능** (IRSA 대비 가장 큰 차이, 멀티클러스터 슬라이드의 핵심 hook).
- 6종 auto session tag(`eks-cluster-name`, `kubernetes-namespace`, `kubernetes-service-account`, ...)가 transitive로 첨부 → ABAC 조건 작성 가능. Cross-account는 association의 `targetRoleArn`(role chaining + externalId)으로 지원.

## 미해결 질문 (확인 필요)
- [x] Pod Identity Agent 노드 권한 → managed `AmazonEKSWorkerNodePolicy`가 `eks-auth:AssumeRoleForPodIdentity` 포함. Findings §Agent runtime requirements
- [x] Agent 장애 시 Pod credential 캐시 동작 → **GitHub 소스로 확인**. (a) Agent 측: 자체 LRU cache 3h TTL + recoverable retry / irrecoverable evict. (b) Application Pod 측: SDK가 받은 credential을 expiration까지 cache (Java v2 default sync, async옵션). 결론: agent unhealthy → 기존 Pod credential 즉시 실패하지 않음. Cold start retry/backoff는 SDK별 구현 차이 (확인 필요 영역). Findings §Agent failure mode & credential caching (GitHub 소스 검증)
- [x] Association은 namespace + SA 단위 → unique key = (cluster, namespace, serviceAccount). 와일드카드/cross-namespace 미지원. Findings §Pod Identity Association API
- [x] 지원 SDK 최소 버전 → Java v2 ≥ 2.21.30, boto3 ≥ 1.34.41, Go v2 ≥ release-2023-11-14, AWS CLI v2 ≥ 2.15.0 등. Findings §SDK compatibility
- [x] IRSA vs Pod Identity 동시 설정 시 어느 쪽 우선 → IRSA(web identity, chain 3rd)가 Pod Identity(container, 5th)보다 먼저 매칭. Findings §IRSA vs Pod Identity precedence + research/01

## Findings
<!-- 사실 + footnote URL을 누적. -->

### Agent runtime requirements
- Pod Identity Agent를 사용하려면 노드 IAM Role이 `eks-auth:AssumeRoleForPodIdentity` 액션을 호출할 수 있어야 한다. AWS managed policy `AmazonEKSWorkerNodePolicy`로 충족하거나 동등한 inline policy를 부여한다.[^pi-agent-setup]
- 권장 inline policy 예시 (`Resource: "*"`)는 AWS 공식 가이드에 그대로 게시되어 있고, 태그 조건으로 어떤 Role을 Pod가 assume할 수 있는지 제한 가능하다고 명시한다.[^pi-agent-setup]
- Agent는 노드에서 `hostNetwork`로 실행되며 link-local 주소 `169.254.170.23`(IPv4) / `[fd00:ec2::23]`(IPv6) 의 포트 `80`/`2703`를 사용한다.[^pi-overview]
- Agent 컨테이너 이미지는 EKS add-on 표준 ECR 레지스트리에서 pull되며, private subnet 노드는 EKS Auth API용 PrivateLink interface endpoint(`com.amazonaws.<region>.eks-auth`)가 있어야 통신 가능.[^pi-agent-setup][^vpc-endpoints]
- EKS Auto Mode 클러스터는 Pod Identity Agent가 사전 설치돼 있어 별도 설치가 불필요하다.[^pi-agent-setup][^eks-addons]

### Failure modes & credential caching
- AWS 공식 문서는 "credential은 Pod Identity Agent에 의해 issue된다"는 동작 모델만 명시할 뿐, **agent 장애 시 기존 Pod의 credential cache 동작을 명시적으로 기술하지 않는다.** 확인 필요.[^pi-how-it-works]
- 확인된 사실: Pod 안에 주입되는 ServiceAccount projected token의 `expirationSeconds`는 `86400`(24시간)이며 audience는 `pods.eks.amazonaws.com`. 이 token이 만료되면 kubelet이 회전한다.[^pi-how-it-works]
- 확인된 사실: `AssumeRoleForPodIdentity` 응답의 `credentials.expiration` 필드로 만료 시각이 반환된다(STS 임시 자격증명 동일 형태). 갱신은 SDK의 container credential provider 책임.[^assume-role-pod-identity]

### Pod Identity Association API
- `CreatePodIdentityAssociation` 필수 입력: `clusterName`(URI), `namespace`, `serviceAccount`, `roleArn`. 선택 입력: `clientRequestToken`(idempotency), `disableSessionTags`, `policy`(session policy), `tags`, `targetRoleArn`(role chaining).[^create-pi-assoc]
- 유일성 키는 (cluster, namespace, serviceAccount). 와일드카드/정규식은 API에 정의되어 있지 않다(필수 string 한 개).[^create-pi-assoc]
- Association은 namespace/serviceAccount가 클러스터에 미리 존재하지 않아도 생성 가능; 단, Pod 동작을 위해서는 동일 이름의 namespace·SA·workload가 필요하다.[^pi-association]
- Cross-namespace 와일드카드는 지원되지 않는다 — `namespace`는 단일 string이다.[^create-pi-assoc]
- Association 변경은 eventually consistent: API 성공 후 수 초 지연이 있을 수 있어, 핵심 high-availability 경로에서 association create/update를 트리거하지 말 것.[^pi-overview][^create-pi-assoc]
- 클러스터당 association 한도: 5,000개.[^pi-overview]

### AssumeRoleForPodIdentity contract
- Endpoint shape: `POST /clusters/{clusterName}/assume-role-for-pod-identity`, host `eks-auth.<region>.api.aws`. Body는 `{"token": "<JWT>"}`만 포함.[^assume-role-pod-identity]
- 응답: `assumedRoleUser`, `audience`(항상 `pods.eks.amazonaws.com`), `credentials`(SigV4 임시 자격증명: accessKeyId/secretAccessKey/sessionToken/expiration), `podIdentityAssociation`(arn/id), `subject`(namespace/serviceAccount).[^assume-role-pod-identity]
- Role session name 포맷: `eks-<clusterName>-<podName>-<randomUUID>` — CloudTrail 추적에 활용 가능.[^assume-role-pod-identity]
- 정의된 에러: `AccessDeniedException`(400), `ExpiredTokenException`(400), `InvalidTokenException`(400), `InvalidParameterException`(400), `InvalidRequestException`(400), `ResourceNotFoundException`(404), `InternalServerException`(500), `ServiceUnavailableException`(503), `ThrottlingException`(429).[^assume-role-pod-identity]

### Add-on lifecycle
- 설치 방법: AWS Management Console, AWS CLI(`aws eks create-addon --addon-name eks-pod-identity-agent`), eksctl, AWS CloudFormation(`AWS::EKS::Addon`).[^pi-agent-setup][^eks-addons]
- 최소 클러스터 버전: Kubernetes `1.28` + EKS platform version `eks.4` 이상 (그 외 listed Kubernetes 버전은 모든 platform에서 지원).[^pi-overview]
- Pod Identity가 **지원되지 않는 환경**: AWS Outposts, Amazon EKS Anywhere, EC2 self-managed Kubernetes(EKS 외부), AWS Fargate(Linux/Windows 모두), Windows EC2 노드.[^pi-overview]
- Pod Identity는 Linux EC2 워커 노드에서만 사용 가능.[^pi-overview]
- Pod Identity Agent Add-on의 노드 권한은 service-account-role-arn(IRSA)로 제공되지 않으며 반드시 노드 IAM role을 사용해야 한다.[^pi-agent-setup]

### SDK compatibility
- Pod Identity의 container credential provider를 지원하는 최소 SDK 버전 (모두 2023-11~ 릴리스)[^pi-min-sdk]:
  - Java v2 ≥ `2.21.30`, Java v1 ≥ `1.12.746`
  - Go v1 ≥ `v1.47.11`, Go v2 ≥ `release-2023-11-14`
  - Python boto3 ≥ `1.34.41`, botocore ≥ `1.34.41`
  - AWS CLI v1 ≥ `1.30.0`, v2 ≥ `2.15.0`
  - JavaScript v2 ≥ `2.1550.0`, v3 ≥ `v3.458.0`
  - Kotlin ≥ `v1.0.1`, Ruby ≥ `3.188.0`, Rust ≥ `release-2024-03-13`, C++ ≥ `1.11.263`, .NET ≥ `3.7.734.0`, PowerShell ≥ `4.1.502`, PHP ≥ `3.289.0`
- 동작 메커니즘: Pod Identity는 SDK 표준 *Container credential provider* slot에서 동작 — IRSA 같은 별도 SDK 코드 경로가 아니라 표준 chain을 그대로 활용한다.[^pi-how-it-works]

### Cross-account & network
- **단일 association은 같은 AWS 계정 내 IAM Role만 직접 매핑한다** (cluster와 같은 계정).[^pi-overview]
- Cross-account 시나리오는 두 가지로 가능:
  1. Application 코드/SDK가 일반 IAM role chaining(`sts:AssumeRole`)을 수행하고, Pod Identity가 첨부한 transitive session tags(`eks-cluster-name`, `kubernetes-namespace` 등)를 cross-account role의 trust/permission 정책 조건에 사용.[^pi-abac]
  2. `CreatePodIdentityAssociation`의 `targetRoleArn` 파라미터를 사용 — EKS가 두 단계 role assumption을 자동 수행한다(association role → target role). 다른 계정 role도 가능하며 `externalId`로 confused-deputy 방지.[^create-pi-assoc][^pi-assoc-data]
- Private cluster: 노드는 EKS Auth API에 도달해야 하므로 private subnet의 경우 `com.amazonaws.<region>.eks-auth` PrivateLink interface endpoint를 만들어야 한다.[^pi-agent-setup][^vpc-endpoints]
- `eks-auth` PrivateLink는 `ap-southeast-5`(Malaysia)에서도 사용 가능하다고 명시(EKS API 자체는 일부 신규 region에서 PrivateLink 미지원이지만 eks-auth는 별도).[^vpc-endpoints]
- Proxy 환경에서는 `169.254.170.23`과 `[fd00:ec2::23]`을 `no_proxy`/`NO_PROXY`에 추가해야 agent로의 요청이 프록시로 잘못 라우팅되지 않는다.[^pi-overview]

### Trust policy shape
- Pod Identity Role의 표준 trust policy 구조[^pi-role][^pi-association]:
  ```json
  {
    "Version": "2012-10-17",
    "Statement": [{
      "Sid": "AllowEksAuthToAssumeRoleForPodIdentity",
      "Effect": "Allow",
      "Principal": { "Service": "pods.eks.amazonaws.com" },
      "Action": ["sts:AssumeRole", "sts:TagSession"]
    }]
  }
  ```
- Principal은 항상 `pods.eks.amazonaws.com` service principal 단일 값. **클러스터별 OIDC URL/account ID에 결합되지 않는다** → 모든 클러스터·계정에 동일 trust policy 재사용 가능 (IRSA와 가장 큰 차이).[^pi-overview][^pi-role]
- `sts:TagSession` 권한이 반드시 필요 — Pod Identity가 자동 session tag를 첨부하기 때문(이 액션이 거부되면 assume 실패).[^pi-role][^pi-association]
- 자동 session tags 6종(transitive=true): `eks-cluster-arn`, `eks-cluster-name`, `kubernetes-namespace`, `kubernetes-service-account`, `kubernetes-pod-name`, `kubernetes-pod-uid`. policy condition에서 `${aws:PrincipalTag/<key>}` 또는 `aws:RequestTag/<key>`로 사용 가능.[^pi-abac]
- Trust policy condition으로 namespace+serviceAccount를 강제하는 패턴이 공식 문서에 제공된다 (`aws:RequestTag/kubernetes-namespace`, `aws:RequestTag/kubernetes-service-account`).[^pi-role]
- `disableSessionTags=true` 사용 시: session policy(`policy` 파라미터)와 함께 사용해야 하며, 이 경우 자동 tag도 송신되지 않아 ABAC 조건이 동작하지 않는다.[^create-pi-assoc][^pi-abac]
- `PackedPolicyTooLarge` 에러를 받을 경우 `disableSessionTags`로 패킹 사이즈를 줄일 수 있다.[^pi-abac][^create-pi-assoc]

### IRSA vs Pod Identity precedence (보충)
- Container credential provider(Pod Identity)는 default chain 안에 한 단계로 들어가 있고, **chain에서 먼저 발견되는 credentials가 사용**된다고 공식 문서가 명시. 워크로드가 chain의 더 앞 단계 credential(예: web identity = IRSA)을 이미 쓰면 Pod Identity association을 추가해도 그것이 그대로 유지되어 안전한 마이그레이션이 가능하다.[^pi-how-it-works][^pi-min-sdk]

[^pi-overview]: https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html
[^pi-how-it-works]: https://docs.aws.amazon.com/eks/latest/userguide/pod-id-how-it-works.html
[^pi-agent-setup]: https://docs.aws.amazon.com/eks/latest/userguide/pod-id-agent-setup.html
[^pi-association]: https://docs.aws.amazon.com/eks/latest/userguide/pod-id-association.html
[^pi-role]: https://docs.aws.amazon.com/eks/latest/userguide/pod-id-role.html
[^pi-abac]: https://docs.aws.amazon.com/eks/latest/userguide/pod-id-abac.html
[^pi-min-sdk]: https://docs.aws.amazon.com/eks/latest/userguide/pod-id-minimum-sdk.html
[^assume-role-pod-identity]: https://docs.aws.amazon.com/eks/latest/APIReference/API_auth_AssumeRoleForPodIdentity.html
[^create-pi-assoc]: https://docs.aws.amazon.com/eks/latest/APIReference/API_CreatePodIdentityAssociation.html
[^pi-assoc-data]: https://docs.aws.amazon.com/eks/latest/APIReference/API_PodIdentityAssociation.html
[^vpc-endpoints]: https://docs.aws.amazon.com/eks/latest/userguide/vpc-interface-endpoints.html
[^eks-addons]: https://docs.aws.amazon.com/eks/latest/userguide/eks-add-ons.html

### Agent failure mode & credential caching (GitHub 소스 검증)

소스 기준 commit: `aws/eks-pod-identity-agent@d4dc0f3` (main HEAD, 2026-04-20).

**Agent 측 caching (in-process)**

- Agent는 자체적으로 `cachedCredentialRetriever`를 운영하며, key는 ServiceAccount JWT token, value는 `AssumeRoleForPodIdentity` 응답이다. 캐시는 LRU + 만료 정책을 사용한다.[^epi-cache] (primary, code)
- Default cache 파라미터: `--max-credential-retention-before-renewal=3h`, `--max-cache-size=2000`, `--max-service-qps=3` (EKS Auth API에 대한 refresh 속도 제한).[^epi-server-flags] (primary, code)
- 캐시 갱신 동작: 만료 임박 entry는 백그라운드 janitor(기본 1분 주기)가 미리 갱신한다. 갱신 실패 시 — 에러가 recoverable면 기존 credential을 `min(남은 ttl, retryInterval+jitter)` 동안 유지하고 다음 sweep에서 재시도. irrecoverable error (예: `AccessDeniedException`, `InvalidTokenException` — `IsIrrecoverableApiError` 분류)면 즉시 캐시에서 evict.[^epi-cache-renewal] [^epi-eksauth-errors] (primary, code)
- `defaultMinCredentialTtl = 15s`: 캐시된 credential의 남은 유효 시간이 15초 미만이면 캐시 hit으로 인정하지 않고 재발급을 시도한다.[^epi-cache] (primary, code)
- 동일 token에 대한 동시 요청은 `internalActiveRequestCache`로 직렬화 — 한 번에 EKS Auth로 한 번만 호출되도록 fan-in (재시도 9회 × 200ms 대기).[^epi-cache] (primary, code)

**Application Pod 측 caching (SDK)**

- AWS SDKs and Tools Reference Guide의 container credential provider 페이지는 "SDKs attempt to load credentials from the specified HTTP endpoint through a GET request" 만 명시할 뿐, **각 SDK의 캐싱·refresh 주기·retry 정책은 SDK별 구현에 위임한다**.[^sdkref-container-fetch] (secondary, AWS docs)
- AWS SDK for Java v2의 `ContainerCredentialsProvider`는 `HttpCredentialsProvider`를 상속하고, builder의 `asyncCredentialUpdateEnabled(Boolean)` 옵션을 지원: "Configure whether the provider should fetch credentials asynchronously in the background. ... By default, this is disabled." → **Java v2 default는 만료 직전 동기 refresh**, 옵션으로 백그라운드 prefetch 활성화 가능.[^java-http-creds-builder] (primary, javadoc)
- 즉 application Pod는 매 AWS API 호출마다 agent를 호출하지 않고, 받은 credential을 expiration까지 보관한 뒤 만료 임박 시 다시 GET한다. SDK 내부 cache가 hot path에 있다.[^java-http-creds-builder] (primary, javadoc, Java v2 한정)

**Failure mode 정리 (질문 2)**

- **기존 application Pod**: `AssumeRoleForPodIdentity` 응답의 `expiration`(보통 약 6시간 전후의 STS 세션) 동안 SDK 측 cache에서 자체 보유. agent DaemonSet이 죽거나 재시작 중이어도 기존 credential은 즉시 무효화되지 않는다 — 만료까지는 유효하다.[^pi-how-it-works] [^java-http-creds-builder] (primary docs+javadoc; agent 코드는 발급 측만 다룸)
- **Refresh 시점에 agent가 unhealthy면**: SDK는 endpoint(`169.254.170.23:80`)에 접속 실패 → SDK별 retry 정책에 따라 재시도. AWS 공식 문서에 표준화된 retry/backoff 사양은 명시되어 있지 않다 — **확인 필요 — SDK별 구현 차이**.[^sdkref-container-fetch] (secondary; 명확한 답 없음)
- **Cold start (Pod가 처음 만들어지고 첫 호출)**: SDK는 `AWS_CONTAINER_CREDENTIALS_FULL_URI` env에 첫 GET을 보낸다. agent가 healthy하지 않으면 첫 API 호출이 즉시 실패하거나 SDK retry로 지연된다. agent 자체는 1분 readiness probe(failureThreshold=30 → 최대 5분), 30초 liveness probe로 readiness/health를 자체 체크하지만,[^epi-daemonset] **SDK 측 첫 호출에 대한 명시적 backoff 정책은 AWS 공식 문서에 없음 — 확인 필요**. (primary manifest + secondary)
- Agent 자신의 EKS Auth 호출은 `service.go`에서 socket timeout 500ms / 전체 timeout 1000ms로 짧게 잡혀 있다 — 즉 agent → EKS Auth 호출 자체는 느슨한 timeout이 아니라 빠른 fail 후 SDK 재시도/agent 캐시 재시도에 의존하는 설계.[^epi-eksauth-service] (primary, code)
- README와 헬름 차트는 agent를 `priorityClassName: system-node-critical`, `terminationGracePeriodSeconds: 30`, `RollingUpdate maxUnavailable: 10%`로 운영해 노드 단위 가용성을 확보하라고 권장한다.[^epi-daemonset] [^epi-values] (primary, manifest)

**결론**
- Agent unhealthy → 기존 Pod credential 즉시 실패하지 않음 (SDK cache가 expiration까지 보유). **확인 — primary 소스로 보장.**
- SDK가 매 API 호출마다 agent를 부르지 않음 (SDK 측 cache 존재). **확인 — Java v2 javadoc 기준 primary, 다른 SDK는 secondary로 동일 패턴 추정.**
- Cold start retry/backoff 정확한 정책 → **확인 필요 — AWS 공식 문서에 표준 명시 없음, SDK별 구현 차이.**

[^epi-cache]: https://github.com/aws/eks-pod-identity-agent/blob/d4dc0f3fedd795b26ac88755238867a2110c7460/internal/credsretriever/refreshing_cache.go
[^epi-server-flags]: https://github.com/aws/eks-pod-identity-agent/blob/d4dc0f3fedd795b26ac88755238867a2110c7460/cmd/server.go#L120-L132
[^epi-cache-renewal]: https://github.com/aws/eks-pod-identity-agent/blob/d4dc0f3fedd795b26ac88755238867a2110c7460/internal/credsretriever/refreshing_cache.go#L226-L268
[^epi-eksauth-errors]: https://github.com/aws/eks-pod-identity-agent/blob/d4dc0f3fedd795b26ac88755238867a2110c7460/internal/cloud/eksauth/errors.go
[^sdkref-container-fetch]: https://docs.aws.amazon.com/sdkref/latest/guide/feature-container-credentials.html
[^java-http-creds-builder]: https://docs.aws.amazon.com/java/api/latest/software/amazon/awssdk/auth/credentials/HttpCredentialsProvider.Builder.html
[^epi-daemonset]: https://github.com/aws/eks-pod-identity-agent/blob/d4dc0f3fedd795b26ac88755238867a2110c7460/charts/eks-pod-identity-agent/templates/daemonset.yaml
[^epi-eksauth-service]: https://github.com/aws/eks-pod-identity-agent/blob/d4dc0f3fedd795b26ac88755238867a2110c7460/internal/cloud/eksauth/service.go
[^epi-values]: https://github.com/aws/eks-pod-identity-agent/blob/d4dc0f3fedd795b26ac88755238867a2110c7460/charts/eks-pod-identity-agent/values.yaml

