# 01 — Pod의 AWS 인증 방법 + Credential Provider Chain

## 요약 (3줄)
- AWS SDK for Java v2 default chain은 6단계 — system props → env → **web identity (IRSA, 3rd)** → profile → **container (Pod Identity, 5th)** → instance profile. boto3·Go v2도 web identity가 container provider보다 먼저.
- 같은 Pod에 IRSA + Pod Identity가 동시에 있으면 **IRSA가 우선** (chain에서 먼저 평가). AWS는 마이그레이션 안전성을 위해 의도적으로 이 동작을 명시.
- Pod Identity Agent는 노드 loopback(`169.254.170.23`)에서 listen하므로 **IMDS hop limit = 1 환경에서도 정상 동작**. 단 EKS Auto Mode는 hop=1 강제.

## 미해결 질문 (확인 필요)
- [x] AWS SDK for Java v2 default credential provider chain 정확한 순서 (공식 문서 URL) → Findings §SDK chain order
- [x] Pod Identity가 chain 안에서 IRSA보다 먼저 평가되는가? → 아니오. IRSA(web identity, 3rd)가 Pod Identity(container, 5th)보다 먼저. Findings §IRSA + Pod Identity precedence
- [x] `AWS_CONTAINER_CREDENTIALS_FULL_URI` / `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE` 환경변수가 Pod Identity의 진입점인가? → 그렇다. EKS가 Pod에 자동 주입. Findings §Pod Identity in chain
- [x] IMDS hop limit 1 설정이 Pod Identity에 영향을 주는가? → 영향 없음. Pod Identity는 IMDS 경로 미사용. Findings §IMDS hop-limit interaction
- [x] Pod Identity Agent 자신이 EKS Auth API endpoint에 접근하기 전 IMDS로 region/credential을 부트스트랩하는지 → **그렇다 (GitHub 소스 primary 확인)**. Agent가 Go SDK v2 default chain으로 IMDS의 EC2 instance role을 사용. DaemonSet은 `hostNetwork: true` + `automountServiceAccountToken: false` → IMDS hop limit=1 환경에서도 정상 동작. Findings §Pod Identity Agent IMDS bootstrap (GitHub 소스 검증)

## Findings
<!-- 사실 + footnote URL을 누적. Stop hook 또는 사람 모두 여기에 append. -->

### SDK chain order

- AWS SDK for Java v2의 `DefaultCredentialsProvider` 체인은 다음 순서로 자격증명 소스를 탐색한다: (1) Java system properties → (2) environment variables → (3) Web identity token + IAM role ARN (`WebIdentityTokenFileCredentialsProvider`) → (4) shared `credentials`/`config` files (`ProfileCredentialsProvider`) → (5) Amazon ECS container credentials (`ContainerCredentialsProvider`) → (6) Amazon EC2 instance IAM role-provided credentials (`InstanceProfileCredentialsProvider`).[^java-chain-order]
- 첫 번째로 모든 필수 설정값을 찾은 provider에서 체인 탐색이 종료된다 ("first wins").[^java-chain-order]
- AWS SDKs and Tools Reference Guide는 모든 SDK가 공통적으로 갖는 표준 credential provider 카테고리(AWS access keys, web identity, login, IAM Identity Center, assume role, container, process, IMDS)를 정의하지만, **각 SDK의 정확한 순서는 다를 수 있음**을 명시한다.[^sdkref-chain]
- AWS SDK for Go v2의 default chain 순서: (1) environment variables (static keys → web identity token) → (2) shared config/credentials files → (3) IAM role for ECS tasks → (4) IAM role for EC2 instance.[^go-chain-order]
- boto3 (Python SDK)는 다음 순서로 탐색한다: (1) `boto3.client()` 파라미터 → (2) `Session` 파라미터 → (3) environment variables → (4) assume role provider → (5) **assume role with web identity provider** → (6) IAM Identity Center → (7) shared credentials file → (8) console login → (9) AWS config file → (10) Boto2 config → (11) container credential provider → (12) EC2 instance metadata.[^boto3-chain-order]
- AWS SDK for JavaScript v3 (Node.js)의 default chain `defaultProvider` 순서: (1) `fromEnv()` (env vars) → (2) `fromSSO()` (IAM Identity Center) → (3) `fromIni()` (shared config/credentials files) → (4) Trusted entity provider (`AWS_ROLE_ARN` 등) → (5) **Web identity token from STS** (IRSA, `fromTokenFile`) → (6) **Amazon ECS / container credentials** (Pod Identity, `fromContainerMetadata`) → (7) Amazon EC2 instance profile (IMDS, `fromInstanceMetadata`).[^node-chain-order]
- 발표 시사점: Java v2 / boto3 / Node.js v3 모두 **web identity (IRSA)가 container credential provider (Pod Identity)보다 먼저** 평가된다. Go v2 default chain 문서는 web identity를 environment variable 단계에 포함시키지만 container provider를 명시적으로 나열하지 않는다 — Go SDK v2는 별도의 `aws/credentials/endpointcreds`/container provider를 통해 `AWS_CONTAINER_CREDENTIALS_FULL_URI`를 지원한다.[^sdkref-container-support]

### IRSA in chain

- IRSA의 진입점은 `AWS_WEB_IDENTITY_TOKEN_FILE` (또는 JVM 시스템 프로퍼티 `aws.webIdentityTokenFile`) + `AWS_ROLE_ARN`(`aws.roleArn`) + 선택적 `AWS_ROLE_SESSION_NAME` 환경변수다.[^java-chain-order]
- Java v2에서는 `WebIdentityTokenFileCredentialsProvider`가 이 환경변수를 읽고, AWS STS `AssumeRoleWithWebIdentity`를 호출해 임시 credential을 받는다. 체인 순서는 **3번째 (system properties → env vars 다음)** 이다.[^java-chain-order]
- EKS의 mutating webhook이 IRSA가 활성화된 Pod에 `AWS_ROLE_ARN`과 `AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token` 환경변수를 자동 주입한다.[^eks-bp-irsa]
- IRSA는 SDK가 직접 STS `AssumeRoleWithWebIdentity`를 호출하므로 AWS 계정의 STS API 쿼터를 소비한다.[^eks-svc-accounts-compare]
- Pod Identity와 달리 IRSA는 OIDC IdP 등록을 요구한다 (계정당 IAM OIDC provider 100개 limit).[^eks-svc-accounts-compare]

### Pod Identity in chain

- EKS Pod Identity가 활성화된 Pod에는 EKS가 다음 환경변수를 주입한다: `AWS_CONTAINER_CREDENTIALS_FULL_URI=http://169.254.170.23/v1/credentials`와 `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE=/var/run/secrets/pods.eks.amazonaws.com/serviceaccount/eks-pod-identity-token`.[^pod-id-how-it-works]
- 이 환경변수들은 **Container Credentials Provider**가 처리하며, AWS SDKs and Tools Reference Guide의 standardized "Container credential provider" 표준에 따라 정의된다.[^sdkref-container]
- Pod Identity Agent는 노드의 DaemonSet으로 실행되며, IPv4 loopback `169.254.170.23` 및 IPv6 `[fd00:ec2::23]`에서 listen한다.[^pod-id-agent-setup]
- SDK는 agent의 HTTP endpoint로 GET 요청을 보내고, agent가 EKS Auth API의 `AssumeRoleForPodIdentity` action을 호출해 임시 credential을 회수해 SDK에 반환한다.[^pod-id-how-it-works] [^assume-role-for-pod-id]
- Java v2 chain 기준 Container Credentials Provider는 **5번째** 위치 (web identity / IRSA보다 뒤, EC2 instance profile보다 앞).[^java-chain-order]

### IRSA + Pod Identity precedence

- 동일 Pod에 IRSA annotation과 Pod Identity association이 모두 설정된 경우, **체인에서 먼저 평가되는 IRSA가 우선**한다. AWS 공식 문서: "If your workloads currently use credentials that are earlier in the chain of credentials, those credentials will continue to be used even if you configure an EKS Pod Identity association for the same workload."[^pod-id-how-it-works]
- 이는 Pod Identity 마이그레이션 안전성을 위한 의도된 설계다 — association을 먼저 만들어두고 IRSA를 제거하면 자연스럽게 Pod Identity로 전환된다.[^pod-id-how-it-works]
- AWS는 EKS에서 가능한 경우 IRSA보다 EKS Pod Identity 사용을 권장한다.[^eks-svc-accounts-compare]

### IMDS hop-limit interaction

- EKS Best Practices: Pod이 IMDS를 사용해야 하는 경우 IMDSv2를 쓰고 EC2 instance hop limit을 **2** 로 늘리라고 권장한다 (default는 1, EKS-eksctl/CloudFormation 템플릿은 자동으로 2로 설정).[^eks-bp-imds-hop]
- Pod Identity Agent는 노드의 DaemonSet pod (host network 아님 — agent는 `hostNetwork: true`를 사용하지 않고 노드 loopback IP `169.254.170.23`에서 listen한다)이며, **EKS Auth API와 통신**해 credential을 가져온다. Application pod이 agent를 호출하는 것은 IMDS 호출이 아니라 노드 loopback HTTP 엔드포인트 호출이다.[^pod-id-agent-setup] [^pod-id-how-it-works]
- 따라서 IMDS hop limit = 1 설정은 **Pod Identity 동작을 차단하지 않는다** (Pod Identity는 IMDS 경로를 사용하지 않음). Application pod도 IMDS hop을 거치지 않고 같은 노드의 agent에 접속한다.[^pod-id-agent-setup]
- 단, **EKS Auto Mode**는 IMDSv2 + hop limit = 1을 강제하며 변경할 수 없다. IMDS access가 필요한 Pod는 `hostNetwork: true`로 실행해야 한다.[^eks-automode-imds]
- 확인 필요 — Pod Identity Agent 자신이 EKS Auth API endpoint로 가는 경로에서 IMDS를 사용해 Region/credential을 부트스트랩하는지에 대한 명시적 AWS 문서 진술은 못 찾음. Agent는 노드 IAM role(`eks-auth:AssumeRoleForPodIdentity` 권한 필요)을 사용한다고 명시되어 있고[^pod-id-agent-setup], 노드 IAM role 자체는 IMDS hop 1로도 노드 kubelet/agent가 접근 가능하므로 실무상 문제 없음. 추가 검증은 별도 연구 단계로.

[^java-chain-order]: https://docs.aws.amazon.com/sdk-for-java/latest/developer-guide/credentials-chain.html
[^sdkref-chain]: https://docs.aws.amazon.com/sdkref/latest/guide/standardized-credentials.html
[^go-chain-order]: https://docs.aws.amazon.com/sdk-for-go/v2/developer-guide/configure-gosdk.html
[^boto3-chain-order]: https://docs.aws.amazon.com/boto3/latest/guide/credentials.html
[^node-chain-order]: https://docs.aws.amazon.com/sdk-for-javascript/v3/developer-guide/setting-credentials-node.html
[^sdkref-container]: https://docs.aws.amazon.com/sdkref/latest/guide/feature-container-credentials.html
[^sdkref-container-support]: https://docs.aws.amazon.com/sdkref/latest/guide/feature-container-credentials.html
[^eks-svc-accounts-compare]: https://docs.aws.amazon.com/eks/latest/userguide/service-accounts.html
[^eks-bp-irsa]: https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html
[^pod-id-how-it-works]: https://docs.aws.amazon.com/eks/latest/userguide/pod-id-how-it-works.html
[^pod-id-agent-setup]: https://docs.aws.amazon.com/eks/latest/userguide/pod-id-agent-setup.html
[^assume-role-for-pod-id]: https://docs.aws.amazon.com/eks/latest/APIReference/API_auth_AssumeRoleForPodIdentity.html
[^eks-bp-imds-hop]: https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html
[^eks-automode-imds]: https://docs.aws.amazon.com/eks/latest/userguide/automode-learn-instances.html

### Pod Identity Agent IMDS bootstrap (GitHub 소스 검증)

소스 기준 commit: `aws/eks-pod-identity-agent@d4dc0f3` (main HEAD, 2026-04-20).

- Agent의 `server` subcommand는 시작 시 `config.LoadDefaultConfig(ctx)`를 호출해 자기 자신용 `aws.Config`를 만든다 — 즉 **Go SDK v2의 default credential provider chain을 그대로 사용**한다.[^epi-server-loadconfig] (primary, code)
- Go SDK v2 `LoadDefaultConfig`의 default chain은 `(1) env vars → (2) shared config files → (3) ECS task role → (4) EC2 instance role via IMDS`이며, 마지막 단계는 `ec2rolecreds` provider가 IMDS로 노드 IAM Role의 임시 credential을 회수한다.[^go-sdk-loadconfig] (primary, AWS docs)
- 기본 helm values에서 agent 컨테이너에 주입되는 환경변수는 `AWS_REGION`(필수, 사용자가 채움) 한 개뿐이고 `AWS_ACCESS_KEY_ID`/`AWS_WEB_IDENTITY_TOKEN_FILE` 등 정적·web-identity 변수는 주입되지 않는다.[^epi-values] (primary, manifest)
- DaemonSet 매니페스트에 `automountServiceAccountToken: false`와 `hostNetwork: true`가 설정돼 있다. 즉 agent Pod는 자체 ServiceAccount token이 없고(IRSA 부트스트랩 불가), 노드 호스트 네트워크에 직접 붙어 IMDS(`169.254.169.254`)에 도달한다.[^epi-daemonset] (primary, manifest)
- `hostNetwork: true`이므로 agent Pod의 IMDS 패킷은 **노드 ENI에서 직접 출발**한다. EC2 IMDS hop limit은 "EC2 인스턴스에서 1 hop 내" 응답을 의미하므로 hop=1이어도 노드 자체는 IMDS에 접근 가능하다 — Pod network namespace를 통과하지 않으므로 hop이 추가되지 않는다.[^epi-daemonset] [^imds-hop-spec] (primary manifest + AWS docs)
- 결론(question 1): Agent는 IMDS로 노드 IAM Role credential과 region을 부트스트랩한다. **`httpPutResponseHopLimit=1`(EKS Auto Mode 기본값)이어도 agent는 hostNetwork로 노드와 동일 네트워크 namespace에 있으므로 정상 동작**한다. 단 worker node 자체에서 IMDS 자체를 막아버리면(`HttpEndpoint=disabled`) agent는 자기 credential을 못 받아 `eks-auth:AssumeRoleForPodIdentity` 호출이 실패한다.[^epi-server-loadconfig] [^epi-daemonset] (inferred from code+manifest+IMDS spec; AWS 공식 문서에서 직접 단정한 문장은 못 찾음)
- 보조 사실: agent에는 hybrid(EKS Hybrid Nodes)용 별도 DaemonSet(`hybrid`, `hybrid-bottlerocket`)이 있으며 이 모드에서는 `--rotate-credentials=true`로 `/eks-hybrid/.aws` 호스트 경로의 shared credentials file을 매 1분마다 회전 로드한다 — IMDS가 없는 환경을 위한 대안 경로.[^epi-values] [^epi-rotater] (primary, code+manifest)
- README는 agent가 "각 worker node에서 실행되며 SDK가 환경변수로 agent endpoint를 찾는다"는 동작 모델만 설명할 뿐, agent 자신의 credential 경로는 명시하지 않는다.[^epi-readme] (secondary, README)

[^epi-server-loadconfig]: https://github.com/aws/eks-pod-identity-agent/blob/d4dc0f3fedd795b26ac88755238867a2110c7460/cmd/server.go#L52-L62
[^go-sdk-loadconfig]: https://docs.aws.amazon.com/sdk-for-go/v2/developer-guide/configure-gosdk.html
[^epi-values]: https://github.com/aws/eks-pod-identity-agent/blob/d4dc0f3fedd795b26ac88755238867a2110c7460/charts/eks-pod-identity-agent/values.yaml
[^epi-daemonset]: https://github.com/aws/eks-pod-identity-agent/blob/d4dc0f3fedd795b26ac88755238867a2110c7460/charts/eks-pod-identity-agent/templates/daemonset.yaml
[^imds-hop-spec]: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-IMDS-existing-instances.html
[^epi-rotater]: https://github.com/aws/eks-pod-identity-agent/blob/d4dc0f3fedd795b26ac88755238867a2110c7460/internal/sharedcredsrotater/rotating_shared_credentials_provider.go
[^epi-readme]: https://github.com/aws/eks-pod-identity-agent/blob/d4dc0f3fedd795b26ac88755238867a2110c7460/README.md

