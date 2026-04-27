# EKS Pod Identity로 더 간편하게 Kubernetes 서비스 권한 관리하기 — 발표 대본 + 상세 리서치

> AWS Korea User Group 마곡 DevOps 소모임 (2026-04-28) · 30분 발표 자료
>
> 본 문서는 발표 슬라이드(`presentation/slides.pdf`, 31장)에 등장하는 **모든 개념과 수치를 AWS 공식 문서 기준으로 재검증**하고, 슬라이드 흐름 그대로 따라가는 발표 대본을 함께 정리한 종합 자료다. 각 사실 주장에는 footnote URL을 부착했고, AWS 공식 문서로 확인되지 않은 항목은 "확인 필요"로 명시했다.
>
> - **저자**: 김태지 (Ethan / KKamJi98), 번개장터 DevSecOps Engineer
> - **저장소**: <https://github.com/KKamJi98/aws-krug-magok-2026>
> - **라이선스**: 슬라이드와 동일하게 [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) 으로 배포된다. 인용된 AWS 공식 문서·블로그·GitHub 코드 발췌는 각 권리자의 약관에 따른다.
> - **검증 방법**: 모든 인용은 AWS 공식 문서·`aws/eks-pod-identity-agent` GitHub 소스를 직접 fetch해 1차 검증했다 (2026-04-28 기준). 공식 문서가 명시하지 않거나 표현이 모호한 항목은 본문에 "확인 필요"로 표기했다.

---

## 목차

| # | 섹션 | 슬라이드 # | 핵심 메시지 |
|---|---|---|---|
| 0 | [서문 — 왜 이 발표인가](#section-0) | 1–2 | 멀티클러스터에서 IRSA를 운영하다 만난 구조적 부담 |
| 1 | [Section 1 — AWS SDK Credential Provider Chain](#section-1) | 3–9 | Java v2 / Boto3 / JS v3 / Go v2 4개 SDK의 chain 순서, IRSA·Pod Identity 진입점, "first match wins" |
| 2 | [Section 2 — IRSA 구조 상세](#section-2) | 10 | Pod Identity Webhook mutation, per-cluster OIDC issuer, SDK가 STS 직접 호출 |
| 3 | [Section 3 — Pod Identity 구조 상세](#section-3) | 11–12, 21–25 | Agent DaemonSet, `AssumeRoleForPodIdentity` API 계약, ABAC session tag 6종, association 모델 |
| 4 | [Section 4 — 멀티클러스터 IRSA 운영 함정](#section-4) | 13–16 | trust policy 길이 quota(2,048 / 8,192), OIDC IdP per-account quota, blue/green trust drift, CloudTrail 사각지대 |
| 5 | [Section 5 — 마이그레이션과 한계](#section-5) | 17–20, 26–28 | chain precedence 안전망, dual-trust pattern, 미지원 환경, SDK 최소 버전, PrivateLink |
| 6 | [Section 6 — 정리](#section-6) | 29–31 | 결합점 이동: per-cluster → per-service |
| D | [부록 D — 예상 Q&A](#부록-d--예상-qa) | — | 발표 후 청중이 던질 가능성 높은 10개 질문 + AWS docs 기반 답변 |
| E | [부록 E — 운영/디버깅 플레이북](#부록-e--운영디버깅-플레이북) | — | 8개 실무 시나리오: 증상 → 원인 → 진단 명령 → 해결 |
| F | [부록 F — 마이그레이션 자동화 패턴](#부록-f--마이그레이션-자동화-패턴) | — | eksctl / Terraform / ACK / CloudFormation / Pulumi 별 association 선언 + blue/green lifecycle |

---

<a id="section-0"></a>

## Section 0 — 서문: 왜 이 발표인가

### 0.1 발표 맥락

EKS Pod Identity는 2023년 11월 re:Invent에서 GA된 비교적 새로운 자격증명 모델이다.[^pi-launch-blog] 기존 IRSA(IAM Roles for Service Accounts)가 IAM OIDC provider와 STS `AssumeRoleWithWebIdentity`를 결합한 **per-cluster 신뢰 모델**이었다면, Pod Identity는 service principal `pods.eks.amazonaws.com`을 trust policy 단일 항목으로 사용하는 **per-service(universal) 신뢰 모델**이다. 본 발표는 두 모델을 옆으로 비교하면서, 멀티클러스터·블루/그린 운영 환경에서 IRSA가 만드는 구조적 부담이 Pod Identity에서 어떻게 사라지는지를 30분 안에 압축해 전달한다.

### 0.2 발표자 소개

- **김태지 (Ethan)** — 번개장터 DevSecOps Engineer
- 다중 EKS 클러스터(blue/green 구조 포함) 환경에서 IRSA 운영, OIDC provider 관리, 클러스터 업그레이드 시 trust policy 갱신 자동화 등을 담당해왔다. 그 과정에서 마주친 운영 부담이 본 발표의 출발점이다.

### 0.3 발표 멘트 (대본)

안녕하세요, 번개장터에서 DevSecOps를 맡고 있는 김태지입니다. 오늘은 EKS Pod Identity가 멀티클러스터 환경에서 IRSA 대비 어떤 운영 차이를 만드는지를 30분 안에 정리해 드리려고 합니다. 슬라이드 한 장 한 장이 결국 한 가지 메시지로 수렴합니다 — **결합점이 per-cluster에서 per-service로 옮겨갔다**. 이 한 줄이 30분 발표의 결론이고, 나머지는 그 결합점이 왜 운영 부담을 만들었고 어떻게 사라졌는지를 풀어가는 과정입니다.

발표 진행 방식은 라이브 데모 없이 아키텍처와 다이어그램 중심으로 갑니다. 30분 안에 9개 섹션을 소화해야 해서 데모가 들어가면 시간이 빠듯하기도 하고, 자격증명 흐름은 정적인 다이어그램이 더 잘 보입니다. 모든 사실 주장에는 AWS 공식 문서 URL을 슬라이드 우하단에 footnote로 달아 두었으니, 발표가 끝나고 GitHub 저장소에서 슬라이드 PDF나 이 통합 자료를 다시 보시면서 출처를 따라가실 수 있습니다.

---

<a id="section-1"></a>

## Section 1 — AWS SDK Credential Provider Chain

> 슬라이드 3–9 / 약 5분 / `research/01-credential-provider-chain.md`

### 1.1 SDK별 chain 순서

각 SDK의 default credential provider chain은 위에서부터 아래로 순차 평가하며, 첫 번째로 유효한 credential을 발견한 provider에서 멈춘다.[^java-chain][^pod-id-how][^standardized]

#### Java SDK 2.x — 6단계 chain[^java-chain]

| # | Provider | 진입 조건 / 환경변수 | 비고 |
|---|---|---|---|
| 1 | `SystemPropertyCredentialsProvider` | `aws.accessKeyId`, `aws.secretAccessKey`, `aws.sessionToken` (JVM system properties) | |
| 2 | `EnvironmentVariableCredentialsProvider` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | |
| 3 | `WebIdentityTokenFileCredentialsProvider` | `AWS_WEB_IDENTITY_TOKEN_FILE` + `AWS_ROLE_ARN` (옵션 `AWS_ROLE_SESSION_NAME`) | **IRSA 진입점**. STS `AssumeRoleWithWebIdentity` 호출. |
| 4 | `ProfileCredentialsProvider` | `~/.aws/credentials`, `~/.aws/config`의 `[default]` profile | SSO/assume-role/process 등으로 위임 |
| 5 | `ContainerCredentialsProvider` | `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI` 또는 `AWS_CONTAINER_CREDENTIALS_FULL_URI` (+ 토큰) | **EKS Pod Identity 진입점** (ECS task role 공용) |
| 6 | `InstanceProfileCredentialsProvider` | EC2 IMDS (`169.254.169.254`) | |

#### Boto3 (Python) — 12단계 chain[^boto3-chain]

순서대로:
1. `boto3.client()` 호출 시 명시 파라미터
2. `Session` 생성 시 명시 파라미터
3. Environment variables (`AWS_ACCESS_KEY_ID` 등)
4. Assume role provider (profile의 `role_arn` + `source_profile`)
5. **Assume role with web identity provider** ← **IRSA 진입점** (`AWS_WEB_IDENTITY_TOKEN_FILE`, `AWS_ROLE_ARN`)
6. AWS IAM Identity Center credential provider
7. Shared credential file (`~/.aws/credentials`)
8. Login with console credentials
9. AWS config file (`~/.aws/config`)
10. Boto2 config file (`/etc/boto.cfg`, `~/.boto`)
11. **Container credential provider** ← **Pod Identity 진입점** (`AWS_CONTAINER_CREDENTIALS_FULL_URI` + `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE`)
12. Instance metadata service (EC2 IMDS)

여기서 핵심은 **IRSA(5)가 Container provider(11)보다 6단계 앞**이라는 점이다. 즉, IRSA env가 남아 있으면 Pod Identity association을 만들어도 Boto3는 IRSA를 계속 쓴다.[^boto3-chain][^pod-id-how]

#### JavaScript SDK v3 (`@aws-sdk/credential-provider-node`)[^js-chain]

AWS 공식 문서가 명시하는 precedence 표 기준 핵심 chain:

| # | Provider 함수 | 비고 |
|---|---|---|
| 1 | `fromEnv()` | `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` |
| 2 | `fromSSO()` | IAM Identity Center |
| 3 | `fromIni()` | shared `config` / `credentials` profile (assume-role, source_profile 등 포함) |
| 4 | Trusted entity provider (`AWS_ROLE_ARN` 기반 assume-role) | profile 외 env 기반 |
| 5 | `fromTokenFile()` — Web identity token (STS) | **IRSA 진입점** (`AWS_WEB_IDENTITY_TOKEN_FILE`, `AWS_ROLE_ARN`) |
| 6 | `fromContainerMetadata()` — ECS / EKS container provider | **Pod Identity 진입점** |
| 7 | `fromInstanceMetadata()` — EC2 IMDS | |

> 확인 필요: AWS 공식 문서 표에는 위 7개 외에 process / login provider 등이 추가로 함께 표기되어 있어, "정확히 7단계"라고 단정하기보다 "핵심 7개 provider 순서"로 이해하는 것이 안전하다. 정확한 chain 구현 순서는 `@aws-sdk/credential-provider-node`의 `defaultProvider` 소스에 의존한다.[^js-chain]

#### Go SDK v2 — 4단계 chain[^go-chain]

1. **Environment variables**
   1. Static credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`)
   2. **Web identity token** (`AWS_WEB_IDENTITY_TOKEN_FILE`) ← **IRSA가 env 단계 안에 포함**
2. Shared configuration files (`~/.aws/credentials`, `~/.aws/config`)
3. **IAM Roles for Tasks** (ECS / EKS container provider) ← **Pod Identity 진입점**
4. IAM Roles for EC2 (IMDS)

Go v2는 web identity를 별도 단계가 아니라 env 단계의 sub-step으로 두고, container provider는 자체 단계를 갖는다.[^go-chain]

### 1.2 First match wins 동작

모든 SDK는 chain을 위에서부터 평가하고 첫 번째로 credential을 반환하는 provider에서 멈춘다.[^standardized][^pod-id-how] AWS 공식 EKS Pod Identity 문서는 다음과 같이 명시한다:

> "EKS Pod Identities have been added to the *Container credential provider* which is searched in a step in the default credential chain. **If your workloads currently use credentials that are earlier in the chain of credentials, those credentials will continue to be used even if you configure an EKS Pod Identity association for the same workload.** This way you can safely migrate from other types of credentials by creating the association first, before removing the old credentials."[^pod-id-how]

이 문장은 IRSA → Pod Identity 마이그레이션 안전망의 근거다. 4개 SDK 모두에서 IRSA 진입점(web identity / token file)이 container provider 앞에 위치하므로, Pod Identity association을 먼저 만들어도 기존 IRSA env가 살아 있는 한 동작이 변하지 않는다.

### 1.3 환경변수 contract

| 시나리오 | 환경변수 | 출처 |
|---|---|---|
| IRSA 진입점 | `AWS_WEB_IDENTITY_TOKEN_FILE`, `AWS_ROLE_ARN` (옵션 `AWS_ROLE_SESSION_NAME`) | Java[^java-chain], Boto3[^boto3-chain] |
| Pod Identity 진입점 | `AWS_CONTAINER_CREDENTIALS_FULL_URI`, `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE` | SDK Reference Container provider 페이지[^container-creds], EKS Pod Identity 동작 문서[^pod-id-how] |
| ECS task role (legacy 호환) | `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI` (+ 옵션 `AWS_CONTAINER_AUTHORIZATION_TOKEN`) | [^container-creds] |

EKS Pod Identity Agent가 mutating 시 Pod manifest에 정확히 다음 두 env를 주입한다는 점이 공식 문서에 코드 예시로 명시되어 있다:[^pod-id-how]

```yaml
env:
  - name: AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE
    value: "/var/run/secrets/pods.eks.amazonaws.com/serviceaccount/eks-pod-identity-token"
  - name: AWS_CONTAINER_CREDENTIALS_FULL_URI
    value: "http://169.254.170.23/v1/credentials"
```

### 1.4 발표 멘트 (대본)

여러분이 EKS에서 SDK를 쓸 때 가장 헷갈리는 게 바로 "내 Pod가 어느 credential을 쓰고 있는가?"입니다. SDK마다 default credential provider chain의 단계 수가 다릅니다. Java SDK v2는 6단계, Boto3는 무려 12단계, JS v3는 핵심 7단계, Go v2는 단 4단계입니다. 단계 수는 다르지만 모든 SDK가 공유하는 한 가지 규칙이 있습니다 — **위에서부터 평가하고, 첫 번째로 유효한 credential을 찾으면 멈춘다**는 first match wins 원칙입니다.

이 원칙이 왜 중요하냐면, IRSA에서 Pod Identity로 마이그레이션할 때 그게 그대로 안전망이 되기 때문입니다. 모든 SDK에서 IRSA 진입점인 `AWS_WEB_IDENTITY_TOKEN_FILE`은 컨테이너 provider보다 앞에 있습니다. Java v2는 3단계(IRSA) vs 5단계(컨테이너), Boto3는 5단계 vs 11단계, Go v2는 같은 env 단계 안의 sub-step이지만 결국 web identity가 컨테이너 provider보다 먼저 평가됩니다. 즉, Pod에 IRSA용 env가 남아 있는 한 Pod Identity association을 새로 만들어도 SDK는 계속 IRSA로 동작합니다. AWS 공식 문서가 그대로 이렇게 적어 두었습니다 — "credentials earlier in the chain ... will continue to be used even if you configure an EKS Pod Identity association for the same workload."

운영자 관점에서 이게 왜 좋냐면, Pod Identity association을 미리 만들어 두고, 충분히 검증한 뒤에 Service Account의 IRSA annotation을 제거하는 식의 단계적 cutover가 가능하기 때문입니다. 반대로 말하면, Pod Identity로 갔다고 생각했는데 실제로는 여전히 IRSA를 쓰고 있는 상태도 만들어질 수 있습니다. 그래서 마이그레이션 검증 시 SDK 디버그 로그 또는 CloudTrail의 `AssumeRoleWithWebIdentity` vs `AssumeRoleForPodIdentity` 호출 분포를 반드시 확인해야 합니다.

### 1.5 인용

[^java-chain]: <https://docs.aws.amazon.com/sdk-for-java/latest/developer-guide/credentials-chain.html>
[^boto3-chain]: <https://docs.aws.amazon.com/boto3/latest/guide/credentials.html>
[^js-chain]: <https://docs.aws.amazon.com/sdk-for-javascript/v3/developer-guide/setting-credentials-node.html>
[^go-chain]: <https://docs.aws.amazon.com/sdk-for-go/v2/developer-guide/configure-gosdk.html>
[^standardized]: <https://docs.aws.amazon.com/sdkref/latest/guide/standardized-credentials.html>
[^container-creds]: <https://docs.aws.amazon.com/sdkref/latest/guide/feature-container-credentials.html>
[^pod-id-how]: <https://docs.aws.amazon.com/eks/latest/userguide/pod-id-how-it-works.html>

---

<a id="section-2"></a>

## Section 2 — IRSA 구조 상세

> 슬라이드 10 / 약 1분 30초 / `research/02-irsa-architecture.md`

### 2.1 Pod Identity Webhook의 mutation 동작

IRSA는 EKS가 운영하는 **Pod Identity Webhook**(mutating admission webhook)을 통해 Pod 스펙을 자동으로 변형한다. 트리거는 ServiceAccount의 annotation `eks.amazonaws.com/role-arn` 이며, 이 annotation이 붙은 SA를 사용하는 Pod에 대해 webhook이 다음을 주입한다.[^pod-identity-webhook-readme][^associate-sa-role]

- **환경변수** `AWS_ROLE_ARN` (예: `arn:aws:iam::123456789012:role/role-app-name`)
- **환경변수** `AWS_WEB_IDENTITY_TOKEN_FILE` = `/var/run/secrets/eks.amazonaws.com/serviceaccount/token`
- 옵션에 따라 `AWS_DEFAULT_REGION`, `AWS_REGION`, `AWS_STS_REGIONAL_ENDPOINTS=regional`
- **projected ServiceAccount token volume**(`aws-token`) 마운트, audience 기본값 `sts.amazonaws.com`[^pod-identity-webhook-readme]

audience는 SA annotation `eks.amazonaws.com/audience`로, 토큰 만료는 `eks.amazonaws.com/token-expiration` annotation으로 덮어쓸 수 있고 둘 다 기본값(audience=`sts.amazonaws.com`, expirationSeconds=86400)을 가진다.[^pod-identity-webhook-readme]

### 2.2 신뢰 체인 — OIDC issuer → IAM OIDC provider → Role trust policy

각 EKS 클러스터는 고유한 **public OIDC discovery endpoint**를 갖는다. 형식은 `https://oidc.eks.<region>.amazonaws.com/id/<UNIQUE_ID>` 이고, 여기서 EKS가 ProjectedServiceAccountToken JWT의 서명 키를 게시한다.[^irsa-overview] 고객은 이 issuer URL을 IAM의 **OpenID Connect identity provider**로 등록(`iam:CreateOpenIDConnectProvider`)해야 STS가 토큰을 검증할 수 있다.[^irsa-overview]

IAM Role의 trust policy는 `Federated` principal로 `arn:aws:iam::<account>:oidc-provider/oidc.eks.<region>.amazonaws.com/id/<UNIQUE_ID>` 을 지정하고, `Action: sts:AssumeRoleWithWebIdentity`, 그리고 `StringEquals` 조건으로 `aud` (= `sts.amazonaws.com`)와 `sub` (= `system:serviceaccount:<namespace>:<service-account>`)를 검사한다.[^associate-sa-role]

```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::123456789012:oidc-provider/oidc.eks.ap-northeast-2.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "oidc.eks.ap-northeast-2.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE:aud": "sts.amazonaws.com",
      "oidc.eks.ap-northeast-2.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE:sub": "system:serviceaccount:team-A:service-A"
    }
  }
}
```

이 신뢰 체인의 핵심은 **per-cluster OIDC issuer**가 신뢰의 출발점이라는 점이다. 클러스터를 새로 만들면 새로운 issuer URL이 생기고, 그 클러스터에 대해 IAM OIDC provider 등록과 모든 Role trust policy의 issuer 갱신이 별도로 필요하다.[^cross-account]

### 2.3 STS 호출 흐름

Pod가 부팅되면 SDK(`AWS SDK`/CLI)는 webhook이 주입한 `AWS_WEB_IDENTITY_TOKEN_FILE` 경로에서 projected SA JWT를 읽고, 이를 그대로 `sts:AssumeRoleWithWebIdentity` API에 전달해 임시 자격증명(access key, secret key, session token)을 받는다.[^arwi][^irsa-overview] 즉, **호출 주체는 Pod 내부의 SDK이며, EKS control plane이나 Pod Identity Agent 같은 노드 컴포넌트가 중간에서 자격증명을 캐시·전달하지 않는다**(Pod Identity와 가장 큰 차이).

STS 측에서는 토큰의 issuer URL로 OIDC discovery를 수행해 EKS가 게시한 공개키로 JWT 서명을 검증하고, role trust policy의 `aud`/`sub` 조건을 평가한 뒤 customer 계정 안에 임시 세션을 발급한다. 세션 기본 수명은 1시간이며 `DurationSeconds`로 15분~role의 max session duration(최대 12시간)까지 지정 가능하다.[^arwi]

**STS quota**: AWS 자격증명으로 호출되는 STS 요청의 기본 한도는 **계정·리전당 600 RPS** 이고, 이 한도는 `AssumeRole`, `GetCallerIdentity`, `GetSessionToken` 등과 **공유**된다.[^iam-sts-quotas] 단, 공식 문서는 "Requests to AWS STS by AWS service principals … do not consume STS request per second quota in your accounts"라고 명시한다.[^iam-sts-quotas] IRSA의 `AssumeRoleWithWebIdentity`는 SDK가 customer 계정으로 직접 호출하는 형태이므로 위 면제 문구에 해당하지 않는다(반면 EKS Pod Identity는 EKS Auth API가 service principal로 동작). `AssumeRoleWithWebIdentity`가 600 RPS 풀을 정확히 어느 비중으로 공유하는지는 quota 페이지의 명시된 6개 operation 목록(`AssumeRole`, `DecodeAuthorizationMessage`, `GetAccessKeyInfo`, `GetCallerIdentity`, `GetFederationToken`, `GetSessionToken`)에 포함돼 있지 않다 — **확인 필요**.[^iam-sts-quotas]

### 2.4 Token / credential lifecycle

projected SA token의 기본 `expirationSeconds`는 **86400(24시간)** 이며 webhook이 자동 설정한다.[^pod-identity-webhook-readme] kubelet은 토큰 수명의 **80%가 경과**하거나 **24시간이 지났을 때** projected token을 자동 갱신해 같은 파일 경로에 다시 쓴다.[^pod-config] SDK 측에서는 `AssumeRoleWithWebIdentity`로 받은 임시 자격증명이 만료되기 전 동일 절차로 재호출해 갱신한다(임시 자격증명 기본 수명 1시간).[^arwi] SDK가 정확히 만료 몇 초 전 refresh를 트리거하는지는 SDK별 구현 세부 사항으로, AWS 공식 문서에서 통합된 수치는 **확인 필요**.

STS endpoint의 경우, 2022년 7월 이후 출시된 AWS SDK major 버전은 `AWS_STS_REGIONAL_ENDPOINTS`의 기본값이 `regional`이며, EKS Pod Identity Webhook은 이 값을 명시적으로 `regional`로 주입할 수 있다(설정 의존).[^sts-regional][^pod-identity-webhook-readme] AWS는 latency·세션 토큰 유효성·redundancy 측면에서 regional STS endpoint 사용을 권장한다.[^associate-sa-role]

### 2.5 발표 멘트 (대본)

IRSA의 신뢰 모델을 한 줄로 요약하면 "**클러스터별 OIDC issuer가 모든 신뢰의 출발점**"입니다. EKS가 클러스터마다 띄우는 public OIDC discovery endpoint가 ProjectedServiceAccountToken JWT의 공개키를 게시하고, 우리는 그 issuer를 IAM에 OpenID Connect provider로 등록하고 다시 Role의 trust policy에서 `Federated` principal과 `sub`/`aud` 조건으로 못박습니다. 이 체인이 끊어지거나 issuer가 바뀌면 Role은 즉시 무력화됩니다.

두 번째로 짚을 부분은 **STS 호출 주체**입니다. IRSA에서 `AssumeRoleWithWebIdentity`는 노드 에이전트가 아니라 **Pod 내부 SDK가 customer 계정으로 직접** 호출합니다. 그래서 토큰 파일 경로(`AWS_WEB_IDENTITY_TOKEN_FILE`)와 환경변수만 webhook이 깔아주고 나머지 credential lifecycle은 전적으로 SDK가 책임집니다. 이 구조 덕분에 SDK 버전·credential provider chain 동작·STS endpoint 설정이 그대로 운영 변수로 들어옵니다.

세 번째로, 이 두 사실을 합치면 **multi-cluster 환경에서 IRSA 운영 부담**이 자연스럽게 드러납니다. 클러스터를 하나 더 만들 때마다 새 OIDC issuer가 생기고, IAM OIDC provider를 추가하고, 모든 관련 Role의 trust policy를 갱신해야 합니다. blue/green 클러스터 전환을 한 번 하려면 trust policy의 issuer를 양쪽에 모두 등록하거나, 잘못된 issuer만 남기면 Pod가 통째로 STS 401을 맞습니다. Pod Identity가 풀려고 한 것이 바로 이 지점입니다.

### 2.6 인용

[^irsa-overview]: <https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html>
[^associate-sa-role]: <https://docs.aws.amazon.com/eks/latest/userguide/associate-service-account-role.html>
[^cross-account]: <https://docs.aws.amazon.com/eks/latest/userguide/cross-account-access.html>
[^arwi]: <https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRoleWithWebIdentity.html>
[^iam-sts-quotas]: <https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_iam-quotas.html>
[^pod-identity-webhook-readme]: <https://github.com/aws/amazon-eks-pod-identity-webhook>
[^pod-config]: <https://docs.aws.amazon.com/eks/latest/userguide/pod-configuration.html>
[^sts-regional]: <https://docs.aws.amazon.com/sdkref/latest/guide/feature-sts-regionalized-endpoints.html>

---

<a id="section-3"></a>

## Section 3 — Pod Identity 구조 상세

> 슬라이드 11–12, 21–25 / 약 5분 / `research/03-pod-identity-architecture.md`

### 3.1 Pod Identity Agent (DaemonSet)

EKS Pod Identity Agent는 클러스터 노드 위에서 Kubernetes `DaemonSet`으로 동작하며, 같은 노드 위 Pod에게만 자격증명을 발급한다.[^pi-restrictions] 노드의 `hostNetwork`를 사용하기 때문에 노드의 link-local 주소를 직접 점유한다. 공식 문서 기준으로 IPv4는 `169.254.170.23`, IPv6는 `[fd00:ec2::23]`을 사용하고, 점유 포트는 `80` (credential proxy)과 `2703` (health/readiness probe)이다.[^pi-restrictions] 오픈소스 구현(`aws/eks-pod-identity-agent`)에서도 동일한 기본값을 확인할 수 있는데, `cmd/server.go`에서 `--port` 기본값 `80`, `--probe-port` 기본값 `2703`, 그리고 bind host 기본값으로 `DefaultIpv4TargetHost = "169.254.170.23"`, `DefaultIpv6TargetHost = "fd00:ec2::23"`이 정의돼 있다.[^repo-server][^repo-config] Helm chart의 daemonset 템플릿은 `hostNetwork: true`와 `automountServiceAccountToken: false`를 명시한다.[^repo-daemonset]

### 3.2 SDK ↔ Agent contract

연관(association)이 걸린 ServiceAccount를 사용하는 Pod에는 Amazon EKS가 mutating admission으로 두 환경변수와 projected SA token volume을 주입한다.[^pod-id-how] 핵심은 다음과 같다.

- `AWS_CONTAINER_CREDENTIALS_FULL_URI=http://169.254.170.23/v1/credentials`
- `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE=/var/run/secrets/pods.eks.amazonaws.com/serviceaccount/eks-pod-identity-token`
- projected volume의 `serviceAccountToken` source는 `audience: pods.eks.amazonaws.com`, `expirationSeconds: 86400` (24h)이다.[^pod-id-how]

AWS SDK는 컨테이너 자격증명 provider 단계에서 `FULL_URI`로 GET 요청을 보내고, `..._TOKEN_FILE`의 내용을 읽어 `Authorization` 헤더 값으로 그대로 사용한다.[^container-creds] Agent 구현도 이 헤더 규약을 따르는데, `pkg/handlers/eks_credential_handler.go`가 `req.Header.Get("Authorization")`으로 SA JWT를 추출한다.[^repo-handler]

### 3.3 Agent ↔ EKS Auth API (`AssumeRoleForPodIdentity`)

Agent는 SDK가 보낸 SA JWT를 받아 EKS Auth API를 호출한다. 엔드포인트와 요청/응답 구조는 다음과 같다.[^api-arpi]

- `POST https://eks-auth.<region>.api.aws/clusters/{clusterName}/assume-role-for-pod-identity`
- 요청 본문: `{"token": "<projected SA JWT>"}` (SigV4 서명됨)[^pi-launch-blog]
- 응답: `assumedRoleUser{arn, assumeRoleId}`, `audience` (= `pods.eks.amazonaws.com` 고정), `credentials{accessKeyId, secretAccessKey, sessionToken, expiration}`, `podIdentityAssociation{associationArn, associationId}`, `subject{namespace, serviceAccount}`[^api-arpi]

세션 만료 시간은 응답의 `credentials.expiration` 필드로 내려오며, AWS 공식 문서·API 레퍼런스에 "STS 세션 길이 N시간" 같은 명시적 보장값은 없다 — **"6시간 고정" 표현은 확인 필요**. 다만 agent 측에는 `--max-credential-retention-before-renewal` 기본값 `3h`가 있어 3시간을 cap으로 캐시·갱신한다.[^repo-server]

### 3.4 Agent's own IAM bootstrap

Agent Pod 자체는 ServiceAccount token을 자동 마운트하지 않는다 (`automountServiceAccountToken: false`).[^repo-daemonset] 따라서 agent 프로세스가 호출하는 Go SDK v2 `LoadDefaultConfig`는 web-identity 단계를 건너뛰고 IMDS step에 도달해 EC2 instance role의 자격증명을 사용한다.[^repo-server] 이 instance role(=node IAM role)이 `eks-auth:AssumeRoleForPodIdentity` 권한을 가져야 하는데, AWS 공식 가이드는 **`AmazonEKSWorkerNodePolicy`** managed policy 사용을 권장한다.[^pi-agent-setup] 실제 managed-policy 레퍼런스 JSON을 보면 해당 액션이 포함돼 있다.[^managed-eksworker]

```json
"Action": [
  "ec2:Describe*",
  "eks:DescribeCluster",
  "eks-auth:AssumeRoleForPodIdentity"
]
```

별도의 `AmazonEKSPodIdentityAgentPolicy`라는 managed policy는 AWS 공식 문서·managed policy 레퍼런스에서 확인되지 않는다 — agent 권한은 노드 role에 붙는 `AmazonEKSWorkerNodePolicy`로 충분하다.[^pi-agent-setup]

### 3.5 ABAC session tags (6종)

EKS Pod Identity는 자격증명을 발급할 때 다음 6개의 session tag를 자동으로 부착한다.[^pi-abac]

| Tag key | 값 |
|---|---|
| `eks-cluster-arn` | 클러스터 ARN |
| `eks-cluster-name` | 클러스터 이름 |
| `kubernetes-namespace` | Pod의 namespace |
| `kubernetes-service-account` | Pod의 SA |
| `kubernetes-pod-name` | Pod 이름 |
| `kubernetes-pod-uid` | Pod UID |

이 6개는 **모두 transitive**다. 공식 문서가 명시적으로 "All of the session tags that are added by EKS Pod Identity are transitive"라고 못박는다 — 즉, role chaining(`AssumeRole`) 시 다음 세션에도 그대로 전파된다.[^pi-abac] 이는 cross-account 시나리오에서 한 번에 하나의 정책으로 권한을 좁힐 수 있는 핵심 메커니즘이다. 정책 내 참조 형식은 `${aws:PrincipalTag/<key>}`이다.[^pi-abac] `disableSessionTags=true`로 끌 수도 있는데, 주된 사유는 packed-policy size 한도 회피이다.[^pi-association]

### 3.6 Association 모델 + 한도

Association은 `(clusterName, namespace, serviceAccount)` 3-tuple을 unique key로 갖는다. `CreatePodIdentityAssociation` API는 `namespace`와 `serviceAccount`를 단일 string으로만 받으며 wildcard·regex·cross-namespace를 허용하지 않는다.[^api-create-assoc] 한도와 일관성 모델은 다음과 같다.[^pi-restrictions]

- 클러스터당 최대 **5,000개** association
- API는 **eventually consistent** — 성공 응답 후 수 초 지연 가능. AWS는 critical hot path에서 association 생성/수정을 피하고 별도 init 루틴으로 분리할 것을 권고한다.[^api-create-assoc]
- ServiceAccount당 1개 IAM role (cross-account가 필요하면 `targetRoleArn`으로 role chaining)[^pi-restrictions][^api-create-assoc]

### 3.7 발표 멘트 (대본)

Pod Identity의 가장 큰 구조적 차이는 **STS 호출의 주체가 누구냐**입니다. IRSA에서는 Pod 안의 SDK가 직접 `AssumeRoleWithWebIdentity`를 호출했죠. Pod Identity에서는 SDK가 호출하는 게 아니라, 노드 위 DaemonSet이 EKS Auth API의 `AssumeRoleForPodIdentity`를 대신 호출하고, 그 응답을 SDK에게 HTTP로 돌려줍니다. SDK 입장에서는 그냥 ECS task처럼 컨테이너 credential provider에 응답하는 평범한 HTTP endpoint를 보는 셈입니다.

두 번째로 trust policy가 평탄해집니다. IRSA는 클러스터마다 다른 OIDC issuer URL을 trust policy의 `Federated` principal로 박아야 했지만, Pod Identity의 trust policy는 universal한 service principal `pods.eks.amazonaws.com` 하나만 신뢰합니다. 어떤 클러스터에서 쓰든 trust policy를 다시 만질 필요가 없고, blue/green 클러스터 마이그레이션도 association만 새로 만들면 됩니다. 단, 클러스터·SA·Pod 식별은 trust policy의 `Condition`에서 6개의 transitive session tag로 얼마든지 좁힐 수 있습니다.

세 번째로 agent는 노드 loopback에 살고 있다는 사실입니다. `hostNetwork: true`로 떠서 IPv4 `169.254.170.23:80`, IPv6 `[fd00:ec2::23]:80`을 점유하고, 같은 노드 Pod의 SDK가 이 link-local 주소로 GET을 칩니다. agent 자신은 SA token을 마운트하지 않고 EC2 instance role로 EKS Auth를 호출하기 때문에, 노드 role에 붙는 `AmazonEKSWorkerNodePolicy`의 `eks-auth:AssumeRoleForPodIdentity` 권한이 곧 agent의 부트스트랩 권한이 됩니다. 그래서 클러스터에 Pod Identity를 켜기 위해 추가로 IAM이 필요한 것은 거의 없습니다 — 노드 role은 이미 갖고 있으니까요.

### 3.8 인용

[^pi-restrictions]: <https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html>
[^pi-agent-setup]: <https://docs.aws.amazon.com/eks/latest/userguide/pod-id-agent-setup.html>
[^pi-abac]: <https://docs.aws.amazon.com/eks/latest/userguide/pod-id-abac.html>
[^pi-association]: <https://docs.aws.amazon.com/eks/latest/APIReference/API_PodIdentityAssociation.html>
[^api-arpi]: <https://docs.aws.amazon.com/eks/latest/APIReference/API_auth_AssumeRoleForPodIdentity.html>
[^api-create-assoc]: <https://docs.aws.amazon.com/eks/latest/APIReference/API_CreatePodIdentityAssociation.html>
[^managed-eksworker]: <https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AmazonEKSWorkerNodePolicy.html>
[^repo-server]: <https://github.com/aws/eks-pod-identity-agent/blob/main/cmd/server.go>
[^repo-config]: <https://github.com/aws/eks-pod-identity-agent/blob/main/configuration/config.go>
[^repo-daemonset]: <https://github.com/aws/eks-pod-identity-agent/blob/main/charts/eks-pod-identity-agent/templates/daemonset.yaml>
[^repo-handler]: <https://github.com/aws/eks-pod-identity-agent/blob/main/pkg/handlers/eks_credential_handler.go>

---

<a id="section-4"></a>

## Section 4 — 멀티클러스터 IRSA 운영 함정

> 슬라이드 13–16 / 약 5분 / `research/05-multi-cluster-irsa-pitfalls.md`

### 4.1 IRSA의 per-cluster 결합 — OIDC issuer가 trust policy에 박힌다

IRSA는 클러스터마다 발급되는 OIDC issuer URL을 통해 IAM Role과 ServiceAccount를 묶는다. 클러스터 한 대를 만들면 EKS는 `https://oidc.eks.<region>.amazonaws.com/id/EXAMPLED539D4633E53DE1B716D3041E` 형태의 issuer를 발급하고, 운영자는 이 URL을 IAM에 OIDC IdP로 등록한 뒤 Role의 trust policy 안에 issuer ARN과 `sub` claim 조건을 박는다.[^irsa-troubleshoot] 이렇게 박힌 issuer는 클러스터 1대에 1:1로 묶이기 때문에, 같은 Role을 다른 클러스터에서 재사용하려면 **trust policy에 또 다른 OIDC IdP 항목을 추가**해야 한다. AWS 공식 launch blog는 이를 한 줄로 못박는다: "You have to update the IAM role's trust policy with the new EKS cluster OIDC provider endpoint each time you want to use the role in a new cluster."[^pi-launch-blog] 즉 클러스터 N대에서 같은 권한을 쓰려면 trust policy 안에 N개의 OIDC 조건이 누적된다.

```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::123456789012:oidc-provider/oidc.eks.ap-northeast-2.amazonaws.com/id/CLUSTER_BLUE_ID" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": { "StringEquals": {
    "oidc.eks.ap-northeast-2.amazonaws.com/id/CLUSTER_BLUE_ID:sub": "system:serviceaccount:team-A:service-A"
  }}
}
```

### 4.2 trust policy 길이 quota — 정확한 수치

IAM Role trust policy의 길이는 IAM 공식 quota 표에 **"Role trust policy length"**라는 이름으로 등재되어 있다. Default는 **2,048 characters**, auto-approved 최대치는 **8,192 characters**다.[^iam-quotas] 이 quota는 Service Quotas 콘솔에서 자동 승인 범위 안에서 증가가 가능한 항목이며, "IAM doesn't count white space when calculating the size of a policy against these limits"라는 주석이 같은 페이지의 inline policy 섹션에 명시되어 있다 — IAM은 **whitespace를 길이 계산에서 제외**한다.[^iam-quotas]

### 4.3 launch blog 인용 — 4개 / 8개 trust entry

AWS Pod Identity launch blog는 이 quota가 IRSA에서 어떻게 체감되는지를 정량적으로 풀어 쓴다:

> "By default, the length of trust policy size is 2048. This means that you can typically define four trust relationships in a single policy. While you can get the trust policy length limit increased, you are typically limited to a maximum of eight trust relationships within a single policy."[^pi-launch-blog]

이 문장이 발표에서 자주 인용되는 **"4의 벽, 8의 벽"**의 출처다. 2,048자에 약 4개, 8,192자에 약 8개라는 비율은 IRSA 표준 trust entry 한 덩어리가 평균 ~500자 안팎이라는 뜻이 된다 (issuer ARN + `sub` 조건 + JSON 보일러플레이트).

### 4.4 EMR docs 인용 — 12개 클러스터, 4096자

EMR on EKS Pod Identity 가이드는 같은 제약을 **다른 숫자**로 기록한다:

> "With IRSA, this was achieved by updating the trust policy of the EMR Job Execution Role. However, due to the 4096 character hard-limit on IAM trust policy length, there was a constraint to share a single Job Execution IAM Role across a maximum of twelve (12) EKS clusters."[^emr-eks-pod-id]

여기서 두 가지를 분리해 읽어야 한다. 첫째, EMR 문서가 말하는 **"4096 character hard-limit"**은 IAM 공식 quota 표의 default 2,048 / max 8,192 어느 쪽과도 일치하지 않는다 — EMR 팀 내부에서 운영상 기준으로 잡은 작업값으로 보이며 IAM 일반 quota와는 별개의 표현이다 (확인 필요: 별도 IAM-side hard-limit인지, EMR-managed trust policy 생성기의 제한인지 명시 출처 미확보). 둘째, 12개 클러스터라는 숫자는 EMR이 자동 생성하는 service account 이름이 IRSA 표준 entry보다 짧기 때문에 같은 4,096자에서 더 많이 들어간다 — 약 4096 / 12 ≈ **340자/entry**, launch blog의 약 500자/entry보다 짧다. trust entry 길이는 namespace·service account 이름 길이에 따라 달라진다는 점을 발표에서 짚어주면 된다.

### 4.5 OIDC IdP per-account quota — 100 / 700

같은 IAM quota 표에 **"OpenId connect providers per account"** 항목이 있다. Default **100**, auto-approved 최대 **700**.[^iam-quotas] 클러스터마다 OIDC IdP 1개를 등록하기 때문에, 단일 AWS 계정에서 돌리는 클러스터 수가 default 기준 100을 넘기 시작하면 IdP quota가 먼저 무릎을 꿇는다. 700까지 늘려도 blue/green을 동시에 돌리거나 PR-preview 클러스터를 매번 띄우는 조직은 금세 한도에 닿는다.

### 4.6 Blue/green 시나리오 — trust 갱신 누락

`cluster-blue`에서 `cluster-green`으로 마이그레이션하는 표준 시나리오를 보자. 두 클러스터를 잠시 병행 운영하다 트래픽을 옮기는 사이, 운영자가 **새 OIDC IdP는 등록했지만 Role trust policy에 green issuer를 추가하지 않은** 상태에서 service-A pod를 green에 띄운다. 그 순간 SDK가 발급받는 web identity token은 IAM 입장에서 정체불명이다. AWS 공식 IRSA troubleshooting 페이지가 정확한 에러 문자열을 기록한다:

> "An error occurred (InvalidIdentityToken) when calling the AssumeRoleWithWebIdentity operation: No OpenIDConnect provider found in your account for https://oidc.eks.region.amazonaws.com/id/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"[^irsa-troubleshoot]

Pod 입장에서는 `AssumeRoleWithWebIdentity` 호출 자체가 실패하기 때문에 AWS API 호출은 한 번도 일어나지 못하고, 애플리케이션 로그에는 SDK가 던지는 `InvalidIdentityToken` 스택트레이스만 남는다.

### 4.7 CloudTrail 사각지대

여기서 운영자가 가장 먼저 들여다보는 곳이 STS CloudTrail 이벤트인데, 그게 비어 있을 수 있다. IAM CloudTrail 통합 문서가 정책을 명시한다:

> "CloudTrail logs all authenticated API requests to IAM and AWS STS API operations. CloudTrail also logs non-authenticated requests to the AWS STS actions, AssumeRoleWithSAML and AssumeRoleWithWebIdentity, and logs information provided by the identity provider. However, **some non-authenticated AWS STS requests might not be logged because they do not meet the minimum expectation of being sufficiently valid to be trusted as a legitimate request**."[^cloudtrail-sts]

`InvalidIdentityToken` 류의 실패는 AWS가 보기에 "sufficiently valid"하지 않은 요청 — 즉 OIDC IdP 자체가 계정에 등록돼 있지 않으면 STS는 요청을 인증 단계에 들이지도 않고 거절한다. 이 경우 CloudTrail의 STS 이벤트 로그에 **해당 호출이 아예 안 잡힐 수 있다**. blue/green 마이그레이션 직후 "pod는 죽어 나가는데 CloudTrail은 조용하다"는 디버깅 함정이 여기서 나온다.

### 4.8 발표 멘트 (대본)

멀티클러스터 운영자라면 이 시나리오가 익숙할 겁니다. 클러스터를 한 대 새로 띄우면 OIDC IdP를 등록하고, 공용으로 쓰던 Role의 trust policy를 열어 issuer 한 줄을 더 박아 넣습니다. 처음 한두 번은 별 거 아닙니다. 그런데 PR-preview 클러스터, 블루그린, 리전별 분리, 팀별 분리가 누적되면 이 trust policy가 어느새 마지막 한 줄을 넣을 자리가 없는 JSON 덩어리가 됩니다.

이게 단순한 비유가 아니라 AWS 공식 수치로 박혀 있다는 게 오늘 슬라이드의 핵심입니다. IAM 공식 quota는 **default 2,048자, auto-approved max 8,192자**입니다. AWS Pod Identity launch blog는 이 한도를 **trust relationship 4개, 늘려도 8개**로 풀어 씁니다. EMR on EKS 가이드는 같은 제약을 **"4096 character hard-limit, 최대 12개 클러스터"**라고 적습니다. 숫자가 조금씩 다른 건 trust entry 한 덩어리의 평균 길이 차이 — service account 이름이 짧으면 더 들어가고 길면 덜 들어갑니다.

여기에 더 까다로운 두 번째 함정이 OIDC IdP per-account quota입니다. **default 100개, max 700개**. 클러스터마다 1개씩 등록하니까 PR-preview를 자동화한 조직은 700에 빠르게 닿습니다. 그리고 이 한도들은 모두 **계정-region 단위**로 누적되기 때문에, 멀티 account 전략 없이 단일 account에 클러스터를 몰아넣으면 양쪽 quota가 동시에 압박을 받습니다.

마지막으로 가장 골치 아픈 디버깅 함정을 강조하고 싶습니다. blue/green 마이그레이션 도중 trust policy 갱신을 깜빡하면 새 클러스터의 pod가 `InvalidIdentityToken: No OpenIDConnect provider found in your account` 에러를 뱉으며 죽습니다. 운영자가 본능적으로 CloudTrail STS 이벤트를 열지만, AWS 공식 정책상 **"non-authenticated AWS STS requests might not be logged because they do not meet the minimum expectation of being sufficiently valid"** — 즉 OIDC IdP가 등록돼 있지 않으면 STS는 요청을 정식 이벤트로 기록하지 않습니다. 애플리케이션 로그만 시끄럽고 CloudTrail은 조용한 디버깅 사각지대가 여기서 만들어집니다. Pod Identity로 가야 하는 이유 중 가장 운영자스러운 이유가 바로 이겁니다.

### 4.9 인용

[^iam-quotas]: <https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_iam-quotas.html>
[^pi-launch-blog]: <https://aws.amazon.com/blogs/containers/amazon-eks-pod-identity-a-new-way-for-applications-on-eks-to-obtain-iam-credentials/>
[^emr-eks-pod-id]: <https://docs.aws.amazon.com/emr/latest/EMR-on-EKS-DevelopmentGuide/setting-up-enable-IAM.html>
[^cloudtrail-sts]: <https://docs.aws.amazon.com/IAM/latest/UserGuide/cloudtrail-integration.html>
[^irsa-troubleshoot]: <https://repost.aws/knowledge-center/eks-troubleshoot-irsa-errors>

---

<a id="section-5"></a>

## Section 5 — 마이그레이션과 한계

> 슬라이드 17–20, 26–28 / 약 4분 / `research/06-pod-identity-migration.md`

### 5.1 Chain precedence가 안전망이 되는 이유

EKS Pod Identity는 SDK의 *default credential provider chain*에서 *Container credential provider* 단계로 주입된다. AWS 공식 문서는 다음과 같이 명시한다: "If your workloads currently use credentials that are earlier in the chain of credentials, those credentials will continue to be used **even if you configure an EKS Pod Identity association for the same workload**."[^pod-id-how] 즉, 같은 Pod에 IRSA의 service account annotation과 Pod Identity association이 동시에 존재하면, IRSA가 사용하는 *Web Identity Token* provider가 Container provider보다 chain에서 앞에 있으므로 IRSA가 먼저 매칭되어 자격증명을 발급한다.[^pi-min-sdk] 같은 문서가 한 번 더 반복해 강조한다: "you can safely migrate from other types of credentials by creating the association first, before removing the old credentials."[^pod-id-how]

### 5.2 안전한 전환 순서 (3-step)

이 chain 우선순위를 안전망으로 활용하면 IRSA → Pod Identity 마이그레이션을 무중단으로 수행할 수 있다.

1. **Pod Identity association 생성**: `CreatePodIdentityAssociation`으로 동일 service account에 대해 association을 추가한다.[^api-create-assoc] 이 시점까지는 IRSA가 chain에서 앞에 있어 동작이 그대로 유지된다.
2. **annotation 제거 + Pod 재기동**: ServiceAccount의 `eks.amazonaws.com/role-arn` annotation을 삭제하고 Deployment를 rollout restart한다. 새 Pod에는 더 이상 web identity 환경변수가 주입되지 않으므로 chain은 자연스럽게 Container provider 단계까지 내려와 Pod Identity 자격증명을 사용한다.[^pod-id-how]
3. **검증 후 IAM Role의 OIDC trust 정리**: Pod 로그·CloudTrail에서 `pods.eks.amazonaws.com` principal로 `AssumeRole`이 호출되는지 확인한 후, IAM Role trust policy에서 OIDC provider statement를 제거한다.

### 5.3 Dual-trust pattern (OIDC + service principal)

전환 기간 동안 같은 IAM Role의 trust policy에 *기존 OIDC provider statement*와 *`pods.eks.amazonaws.com` service principal statement* 두 개를 함께 두는 패턴을 권장한다. AWS 공식 문서는 Pod Identity가 요구하는 trust policy(`Service: pods.eks.amazonaws.com`, `sts:AssumeRole` + `sts:TagSession`)를 명시한다.[^pi-association] 다만 "OIDC와 service principal을 한 Role에 같이 두라"는 *dual-trust 결합 패턴* 자체를 명시적으로 'recommended'로 권고하는 공식 문구는 (확인한 페이지 기준) 보이지 않는다. 따라서 본 발표에서는 **공식 권장이 아닌 community/operational 패턴**으로 표기하고, 근거는 (a) trust policy는 statement 다수를 허용한다는 IAM 일반 동작과 (b) 5.1·5.2에서 인용한 chain precedence 동작에 둔다. (확인 필요: AWS 공식 blog/best-practice 페이지에서 명시 권고 여부)

### 5.4 미지원 환경

공식 *EKS Pod Identity restrictions* 섹션 기준 다음 환경에서는 **사용할 수 없다**.[^pi-restrictions]

- **AWS Fargate (Linux/Windows)** — "Linux and Windows pods that run on AWS Fargate (Fargate) aren't supported."[^pi-restrictions]
- **Windows EC2 노드** — "Pods that run on Windows Amazon EC2 instances aren't supported."[^pi-restrictions]
- **AWS Outposts**[^pi-restrictions]
- **Amazon EKS Anywhere**[^pi-restrictions]
- **EC2 위에서 직접 운영하는 self-managed Kubernetes** — "The EKS Pod Identity components are only available on Amazon EKS."[^pi-restrictions]

### 5.5 SDK 최소 버전

워크로드 컨테이너의 SDK가 Container credential provider의 새 환경변수(`AWS_CONTAINER_CREDENTIALS_FULL_URI`, `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE`)를 지원해야 한다. AWS 공식 *Use pod identity with the AWS SDK* 페이지의 명시 버전이다.[^pi-min-sdk]

| SDK | 최소 버전 |
|---|---|
| Java v2 | `2.21.30` |
| Java v1 | `1.12.746` |
| Go v1 | `v1.47.11` |
| Go v2 | `release-2023-11-14` |
| Python boto3 / botocore | `1.34.41` / `1.34.41` |
| AWS CLI v1 / v2 | `1.30.0` / `2.15.0` |
| JavaScript v3 | `v3.458.0` |
| Kotlin | `v1.0.1` |
| Ruby (aws-sdk-core) | `3.188.0` |
| Rust | `release-2024-03-13` |
| .NET | `3.7.734.0` |

(전체 목록은 [^pi-min-sdk]). 이보다 낮은 버전은 Container provider 단계에서 Pod Identity 토큰 파일을 인식하지 못하므로, chain은 그대로 통과해 결국 EC2 instance profile (node role)로 fallback된다 — 운영자가 의도한 least-privilege가 깨진다는 점이 핵심 함정이다.[^pod-id-how]

### 5.6 Private cluster — eks-auth PrivateLink

Pod Identity Agent는 노드에서 **EKS Auth API**(`AssumeRoleForPodIdentity`)를 호출한다.[^pod-id-how] outbound internet이 없는 private cluster에서는 다음 interface endpoint가 필수다.

- **PrivateLink service name**: `com.amazonaws.<region-code>.eks-auth`[^vpc-endpoints][^private-clusters]
- **Regional endpoint hostname**: `eks-auth.<region>.api.aws` (예: `eks-auth.ap-northeast-2.api.aws`)[^eks-endpoints]

agent prerequisites 페이지도 동일 요구를 명시한다: "If you are using private subnets for your nodes, you must set up an AWS PrivateLink interface endpoint for the EKS Auth API."[^pi-agent-setup]

### 5.7 Proxy gotcha

HTTP proxy를 강제하는 환경에서는 agent의 link-local 주소를 우회 대상에 포함시켜야 한다. *EKS Pod Identity considerations*는 직접 권고한다: "For pods using a proxy, add `169.254.170.23` (IPv4) and `[fd00:ec2::23]` (IPv6) to the `no_proxy/NO_PROXY` environment variables to prevent failed requests to the EKS Pod Identity Agent."[^pi-restrictions] 이 두 주소는 agent setup 문서에서도 동일하게 정의된다.[^pi-agent-setup] 즉 AWS **공식 권장**이다.

### 5.8 Cross-account via association `targetRoleArn`

`CreatePodIdentityAssociation`은 `roleArn`(account A)과 `targetRoleArn`(account A 또는 B) 두 ARN을 함께 받는다. AWS 공식 정의: "EKS Pod Identity automatically performs two role assumptions in sequence: first assuming the role in the association that is in this account, then using those credentials to assume the target IAM role."[^api-create-assoc] 즉 Pod Identity가 *role chaining*을 서버측에서 대신 수행하므로, 워크로드 코드는 단일 자격증명만 다룬다. **Confused-deputy 방어**용 `externalId`도 association 모델에 내장돼 있다: "You put this value in the trust policy of the target role, in a `Condition` to match the `sts.ExternalId`."[^pi-association]

### 5.9 발표 멘트 (대본)

도입을 망설이는 가장 큰 이유는 보통 "이미 잘 굴러가는 IRSA를 건드리다가 전환 중에 장애가 나면 어떡하지"입니다. 결론부터 말씀드리면, 그 걱정의 상당 부분은 SDK credential provider chain 자체가 안전망 역할을 해주기 때문에 구조적으로 해결됩니다. AWS 공식 문서가 직접 인용할 수 있는 문장으로 보장합니다 — "credentials earlier in the chain ... will continue to be used even if you configure an EKS Pod Identity association for the same workload". Web identity token provider가 Container provider보다 앞에 있으니까, association을 먼저 만들고 annotation은 나중에 제거하는 순서로만 가면, 같은 Pod에 두 설정이 공존하는 짧은 구간에도 IRSA가 그대로 자격증명을 내줍니다.

대신 **첫날 막히기 쉬운 함정 세 가지**가 있는데, 운영자 입장에서 사전 체크리스트로만 다뤄도 충분합니다. 첫째는 SDK 최소 버전입니다. Java v2 `2.21.30`, boto3 `1.34.41`, Go v2 `release-2023-11-14`, JS v3 `v3.458.0`, AWS CLI v2 `2.15.0` — 이 다섯 가지 미만이면 Container provider가 새 환경변수를 인식하지 못해 조용히 노드 IAM role로 fallback합니다. 권한이 *늘어난 채로* 동작해서 알람도 안 뜨고 후행 보안 리뷰에서야 발견되는 패턴이 가장 위험합니다.

둘째는 미지원 환경입니다. Fargate(Linux·Windows 둘 다), Windows EC2, EKS Anywhere, Outposts에서는 아예 동작하지 않으니 마이그레이션 대상 범위를 사전에 솎아내야 합니다. 셋째는 private cluster의 PrivateLink — `com.amazonaws.<region>.eks-auth` interface endpoint와, proxy를 쓰는 환경이라면 `169.254.170.23`/`[fd00:ec2::23]`를 `no_proxy`에 넣는 것입니다. 두 가지는 AWS 공식 문서에 명시된 요구·권장이므로 사내 표준 baseline에 그대로 박아두면 됩니다. 그리고 cross-account가 필요한 팀은 association의 `targetRoleArn`만 넣으면 EKS가 role chaining을 서버측에서 대신 처리해주므로, 코드 레벨에서 `STS:AssumeRole`을 직접 호출하던 wrapper를 제거할 수 있다는 점도 같이 기억해 두시면 좋겠습니다.

### 5.10 인용

[^pi-min-sdk]: <https://docs.aws.amazon.com/eks/latest/userguide/pod-id-minimum-sdk.html>
[^vpc-endpoints]: <https://docs.aws.amazon.com/eks/latest/userguide/vpc-interface-endpoints.html>
[^private-clusters]: <https://docs.aws.amazon.com/eks/latest/userguide/private-clusters.html>
[^eks-endpoints]: <https://docs.aws.amazon.com/general/latest/gr/eks.html>

---

<a id="section-6"></a>

## Section 6 — 정리

> 슬라이드 29–31 / 약 1분

### 6.1 오늘의 take-away 5가지 (Slide 29)

1. **Credential provider chain**을 이해해야 IRSA·Pod Identity의 차이가 보인다 — IRSA = web identity (3rd), Pod Identity = container (5th).
2. **IRSA 멀티클러스터 한계는 정량적**: trust policy 2,048자(증액 시 8,192자) → 한 Role에 trust 관계 ~4개(증액 시 ~8개)가 사실상 상한.
3. **Blue/green 클러스터 교체에서 trust 갱신 누락은 CloudTrail로 추적 어려움** — `InvalidIdentityToken`은 client-side로 분류돼 로깅 누락 가능.
4. **Pod Identity는 trust policy를 단일 service principal로 고정** + **STS quota 미사용** + **자동 session tag 6종으로 ABAC**.
5. **마이그레이션은 chain precedence 덕분에 안전** — association 먼저, annotation 나중.

### 6.2 결합점이 바뀌면 운영 토폴로지가 바뀐다 (Slide 30)

- IRSA의 운영 부담은 "OIDC trust 관리"라는 **per-cluster 결합**에서 생긴다.
- Pod Identity는 trust 결합을 **per-service(`pods.eks.amazonaws.com`)**로 옮겨, 클러스터 수가 늘어도 trust policy는 변하지 않는다.
- 결합점이 바뀌면 **운영 토폴로지 자체가 단순해진다** — blue/green·failover·신규 클러스터 추가에서 IAM 작업이 사라진다.
- 이것이 30분 발표의 한 줄 결론이다.

### 6.3 발표 멘트 (대본)

마지막 한 장은 정리입니다. 30분 동안 이야기한 모든 내용을 한 줄로 압축하면 — **결합점이 바뀌면 운영 토폴로지가 바뀐다** — 입니다. IRSA의 모든 운영 부담은 trust policy가 클러스터별 OIDC issuer URL에 묶여 있다는 사실, 즉 per-cluster 결합에서 출발합니다. Pod Identity는 그 결합을 service principal `pods.eks.amazonaws.com` 한 줄로 평탄화했고, 그 결과로 trust policy 길이 한도 자체가 무의미해지고, blue/green 클러스터 교체에서 IAM 작업이 사라지고, OIDC provider per-account quota 부담도 사라집니다.

도입을 망설이는 가장 큰 이유였던 "전환 중 장애"는 SDK credential provider chain의 first-match-wins 동작이 그대로 안전망이 됩니다. Pod Identity association을 먼저 만들어두면 워크로드는 여전히 IRSA로 돌아가고, IRSA annotation을 제거하는 시점에만 자연스럽게 전환됩니다. 미지원 환경(Fargate, Windows EC2 노드, EKS Anywhere, Outposts)은 IRSA를 유지하면 되고, 지원 환경부터 점진적으로 옮겨가는 것이 현실적인 경로입니다.

오늘 발표는 여기까지입니다. 자료는 GitHub 저장소 `KKamJi98/aws-krug-magok-2026`에 슬라이드 PDF와 이 통합 자료(`presentation/script.md`), 리서치 노트(`research/`), 다이어그램 소스(`presentation/assets/diagrams/`)까지 모두 올려두었으니 출처와 함께 다시 확인하실 수 있습니다. 질문 받겠습니다.

---

## 부록 A — 슬라이드 ↔ 다이어그램 ↔ 리서치 매핑

| 슬라이드 # | 제목 | 다이어그램 | 리서치 노트 |
|---|---|---|---|
| 1 | 표지 | — | — |
| 2 | 목차 | — | — |
| 3 | Pod 안에서 AWS API를 호출하려면? | — | research/01 |
| 4 | AWS SDK Default Credential Provider Chain (Java v2) | 01-credential-chain | research/01 |
| 5 | Python (Boto3) 12단계 중 핵심 6단계 | 01b-credential-chain-python | research/01 |
| 6 | JavaScript v3 (Node.js) 7단계 default chain | 01c-credential-chain-js | research/01 |
| 7 | Go v2 4단계 default chain | 01d-credential-chain-go | research/01 |
| 8 | 핵심 동작: First Match Wins | — | research/01 |
| 9 | 같은 Pod에 둘 다 있으면? | — | research/01 |
| 10 | IRSA 구조 | 02-irsa-flow | research/02 |
| 11 | Pod Identity 구조 | 03-pod-identity-flow | research/03 |
| 12 | 한 장 비교: 신뢰·연결·운영 5축 | 04-irsa-vs-pi-comparison | research/04 |
| 13 | 그런데 왜 IRSA를 멀티클러스터에서 쓰면 곤란한가 | — | research/05 |
| 14 | EKS Cluster Upgrade (Blue/Green) | — | research/05 |
| 15 | trust policy 길이의 벽 | 05-multi-cluster-pitfalls | research/05 |
| 16 | 장애가 일어났다, 근데 CloudTrail에 없다 | — | research/05 |
| 17 | Pod Identity의 답 — Trust는 한 줄, 식별은 Tag로 | — | research/03 |
| 18 | Pod Identity의 trust policy — 단일 service principal | — | research/03 |
| 19 | 멀티클러스터 식별은 ABAC session tag로 | — | research/03 |
| 20 | Cross-account & OIDC IdP quota — 모두 정리 | — | research/03, 05 |
| 21 | Pod Identity 동작 한 장 — 7-step flow | 03-pod-identity-flow | research/03 |
| 22 | Agent 자체는 어떻게 동작하나 | — | research/03 |
| 23 | AssumeRoleForPodIdentity — API 계약 | — | research/03 |
| 24 | Association = (cluster, namespace, serviceAccount) | — | research/03 |
| 25 | 운영 시 주의 — Network/Proxy | — | research/03, 06 |
| 26 | 운영 부담은 어떻게 줄어드는가 — 4가지 | — | research/06 |
| 27 | 마이그레이션은 단계적으로 — chain precedence가 안전망 | — | research/06 |
| 28 | 솔직한 한계 — 도입 전 점검 1줄 | — | research/06 |
| 29 | 오늘의 take-away 5가지 | — | — |
| 30 | 왜 멀티클러스터에서 Pod Identity인가 — 한 장 | — | — |
| 31 | Thank you / Q&A | — | — |

---

## 부록 B — 빌드 / 재현

```bash
# 의존성 (1회)
make install
# 다이어그램 HTML → webp
make diagrams
# Marp PDF 빌드
make slides
# 라이브 미리보기
make watch
```

필수: Node 18+, `playwright` Chromium (`npx playwright install chromium`), `sharp` (`make install`이 처리).

---

## 부록 C — 인용 문헌 (전체 카탈로그)

본 문서에서 사용한 모든 footnote URL은 각 섹션 끝에 정리되어 있다. 카테고리별 전체 카탈로그는 [`references.md`](../references.md)를 참고.

핵심 출처:

- AWS — [IAM and AWS STS quotas](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_iam-quotas.html)
- AWS — [EKS Pod Identity overview](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
- AWS — [EKS Pod Identity how-it-works](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-how-it-works.html)
- AWS — [IAM roles for service accounts (IRSA)](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- AWS — [EKS Best Practices: Identity and Access Management](https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html)
- AWS — [`AssumeRoleForPodIdentity` API](https://docs.aws.amazon.com/eks/latest/APIReference/API_auth_AssumeRoleForPodIdentity.html)
- AWS — [`AssumeRoleWithWebIdentity` API](https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRoleWithWebIdentity.html)
- AWS — [Pod Identity ABAC session tags](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-abac.html)
- AWS — [Pod Identity minimum SDK versions](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-minimum-sdk.html)
- AWS — [VPC interface endpoints (eks-auth)](https://docs.aws.amazon.com/eks/latest/userguide/vpc-interface-endpoints.html)
- AWS — [CloudTrail logging for IAM/STS](https://docs.aws.amazon.com/IAM/latest/UserGuide/cloudtrail-integration.html)
- AWS — [`AmazonEKSWorkerNodePolicy` managed policy reference](https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AmazonEKSWorkerNodePolicy.html)
- AWS Blog — [Amazon EKS Pod Identity launch](https://aws.amazon.com/blogs/containers/amazon-eks-pod-identity-a-new-way-for-applications-on-eks-to-obtain-iam-credentials/)
- GitHub — [`aws/eks-pod-identity-agent`](https://github.com/aws/eks-pod-identity-agent)
- GitHub — [`aws/amazon-eks-pod-identity-webhook`](https://github.com/aws/amazon-eks-pod-identity-webhook)
- AWS re:Post — [IRSA troubleshooting (`InvalidIdentityToken`)](https://repost.aws/knowledge-center/eks-troubleshoot-irsa-errors)

---

## 부록 D — 예상 Q&A

각 Q에는 슬라이드/대본에서 다 다루지 못한 보충 답변과 출처를 함께 정리한다. 모든 사실 주장은 AWS 공식 문서를 우선 인용했고, 확인이 어려운 부분은 "확인 필요"로 명시한다.

### D.1 — "SA마다 IAM Role을 따로 만들어야 하나요? 단일 Role + ABAC만으로 가능한가요?"

EKS 베스트 프랙티스 가이드는 **"Use one IAM role per application"**을 명시적으로 권장한다.[^bp-one-role] 애플리케이션별로 격리(blast radius 축소)하고 최소 권한을 적용하기 쉬워서다. 다만 같은 가이드는 **"When using ABAC with EKS Pod Identity, you may use a common IAM role across multiple service accounts and rely on their session attributes for access control. This is especially useful when operating at scale"**라고 ABAC 패턴도 공식적으로 인정한다.[^bp-one-role] 즉 "Role 분리"가 디폴트, "공용 Role + ABAC"는 규모가 커서 Role 수를 관리하기 부담스러울 때 선택하는 보완책이다. Pod Identity는 `eks-cluster-arn`, `kubernetes-namespace`, `kubernetes-service-account` 등 6개 session tag를 자동 주입하므로 ABAC 조건문 작성이 IRSA보다 용이하다.[^d-pod-id-abac] 결론: **IRSA 시절부터 자리잡은 "앱당 Role" 원칙은 그대로 유지하되, 수백~수천 SA로 늘어나는 워크로드에서만 ABAC 기반 공용 Role을 검토**한다.

### D.2 — "association 5,000개 한도를 넘으면 어떻게 하나요?"

공식 문서는 **"Up to 5,000 EKS Pod Identity associations per cluster"**라고만 명시한다.[^d-pod-id-limits] 그리고 EKS service quotas 페이지는 **"Adjustments to the following components are not supported in Service Quotas: Pod Identity associations per cluster"**라고 못박아, **Service Quotas 콘솔에서 quota 증액 신청이 불가능한 항목**임을 명확히 한다.[^eks-quotas] 공식 문서에는 "soft limit인지 hard limit인지" 명시 표현이 없으나, Service Quotas adjustable 대상이 아니라는 점은 사실상 hard limit으로 운영해야 함을 시사한다 (증액이 필요하면 AWS Support 케이스를 통한 별도 요청 경로가 필요할 수 있음 — **확인 필요**). 실무 회피책은 (1) 공용 Role + ABAC로 association 수 자체를 줄이거나, (2) 클러스터를 분할(tenant별/도메인별)해서 association을 분산하는 것이다. 5,000개에 근접하기 전에 metrics(association count)를 모니터링해 임계 알람을 거는 게 안전하다.

### D.3 — "Karpenter / Auto Mode에서 Pod Identity가 잘 동작하나요?"

**Auto Mode**: 공식 문서는 **"You do not have to install the EKS Pod Identity Agent on EKS Auto Mode clusters. This capability is built into EKS Auto Mode."**라고 명시한다.[^auto-mode-id][^d-agent-setup] 따로 add-on 설치가 필요 없다. **Karpenter (managed Karpenter 또는 self-managed)**: agent는 DaemonSet이므로 Karpenter가 띄운 노드에도 자동으로 스케줄된다. 단 **노드 IAM Role에 `eks-auth:AssumeRoleForPodIdentity` 권한이 반드시 있어야 한다**.[^d-agent-setup] AWS managed policy인 `AmazonEKSWorkerNodePolicy`에 이미 포함되어 있으므로 Karpenter NodeClass의 `role`이 이 managed policy를 attach하고 있다면 추가 작업이 없다.[^d-agent-setup] private subnet 노드라면 EKS Auth API용 PrivateLink VPC endpoint(`com.amazonaws.<region>.eks-auth`) 설정이 추가로 필요하다.[^d-agent-setup] Karpenter NodeClass에서 커스텀 노드 Role을 쓰는 환경이라면 이 두 가지(`eks-auth:AssumeRoleForPodIdentity` 권한, PrivateLink endpoint)를 사전 점검해야 한다.

### D.4 — "NetworkPolicy로 link-local 169.254.170.23 egress가 차단되면?"

agent는 **호스트의 link-local 주소 `169.254.170.23` (IPv4) 또는 `[fd00:ec2::23]` (IPv6)의 80/2703 포트**를 사용해 Pod에 credential을 제공한다.[^d-pod-id-limits][^d-agent-setup] Pod이 이 link-local로의 egress를 NetworkPolicy로 차단하면 SDK가 credential을 받지 못해 401/403 또는 timeout이 발생한다. AWS 문서는 NetworkPolicy 관련 직접 가이드는 두지 않지만, **"For pods using a proxy, add `169.254.170.23` (IPv4) and `[fd00:ec2::23]` (IPv6) to the `no_proxy/NO_PROXY` environment variables to prevent failed requests to the EKS Pod Identity Agent"**라는 운영 권고를 명시한다.[^d-pod-id-limits] Calico/Cilium 사용 시 권장 패턴: (1) default-deny egress NetworkPolicy를 두되 link-local CIDR(`169.254.170.23/32`)을 명시적 허용으로 추가, (2) IPv6 cluster라면 `fd00:ec2::23/128`도 같이 허용, (3) `hostNetwork: true` Pod은 NetworkPolicy 적용 대상이 아님(IMDS와 동일 경로 사용).[^d-pod-id-limits]

### D.5 — "기존 cross-account `sts:AssumeRole` wrapper를 어떻게 정리하나요?"

2025년 6월 GA된 **target IAM role 기능**으로 코드의 wrapper를 제거할 수 있다.[^cross-account-blog][^target-role] 동작 원리: Pod Identity association에 (a) cluster 계정의 EKS Pod Identity Role과 (b) 다른 계정의 **Target IAM Role** ARN을 함께 등록하면, agent가 두 단계 role chaining (`AssumeRole` → `AssumeRole`)을 자동 수행해 cross-account 임시 자격증명을 SDK에 전달한다.[^target-role] 애플리케이션 코드는 default credential chain을 그대로 사용하면 되므로 기존 `boto3.client('sts').assume_role(...)` 같은 wrapper를 삭제하고 SDK 기본 client만 쓰면 된다. 주의점 두 가지: (1) **caching** — target role을 쓰면 credential 캐시가 6시간이 아닌 **59분**으로 짧아진다.[^target-role] (2) **trust policy** — Target Role의 trust policy에 source role ARN과 (옵션) `aws:RequestTag/eks-cluster-arn` 등 PrincipalTag 조건을 걸어 cluster/namespace/service-account를 강제 검증해야 안전하다.[^target-role]

### D.6 — "Pod가 장시간 떠 있을 때 credential 갱신, agent 재시작 시 영향?"

Pod에 마운트되는 projected service account token은 **`expirationSeconds: 86400` (24시간)**이고 kubelet이 80% 시점에 자동 rotate한다.[^d-pod-id-howitworks][^bp-irsa-token] agent는 이 token을 받아 EKS Auth API의 `AssumeRoleForPodIdentity`를 호출해 임시 자격증명을 발급한다.[^d-assumerole-pi] 캐싱 정책은: target role이 **없을 때 6시간**, **target role이 있을 때 59분** 캐시.[^target-role] 즉 6시간 이상 떠 있는 Pod은 SDK가 만료 직전 자동으로 agent에 재요청해 새 credential을 받아간다. **agent가 죽으면**: agent는 DaemonSet이라 kubelet이 자동 재기동하고, agent가 죽어 있는 동안 SDK가 캐시한 credential은 만료까지 그대로 유효하지만, 만료 후 갱신 시도는 connection refused로 실패한다 (agent가 link-local 80/2703을 listen 못 하므로).[^d-pod-id-limits] 따라서 add-on health 모니터링(`kubectl get ds -n kube-system eks-pod-identity-agent`)과 PDB는 운영 필수다. **agent 자체의 재시작 resilience 정확한 동작 — 확인 필요**.

### D.7 — "Pod Identity는 CloudTrail에 어떻게 찍히고, audit에 충분한가요?"

agent가 호출하는 API는 **`AssumeRoleForPodIdentity`**이고, 응답의 role session name은 다음 형식이다: **`eks-<clusterName>-<podName>-<random UUID>`**.[^d-assumerole-pi] 따라서 CloudTrail의 `userIdentity.arn` 또는 `assumedRoleUser.arn`을 grep하면 어느 cluster의 어느 Pod이 자격증명을 받아갔는지 추적할 수 있다. 자동 부착되는 6개 session tag(`eks-cluster-arn`, `kubernetes-namespace`, `kubernetes-service-account`, `kubernetes-pod-name`, `kubernetes-pod-uid`, `eks-cluster-name`)도 CloudTrail event의 session 정보에 포함되어 ABAC 감사에 활용 가능하다.[^d-pod-id-abac][^session-tags-ctlogs] IRSA의 `InvalidIdentityToken` 같은 OIDC 기반 인증 실패는 Pod Identity에서는 `InvalidTokenException`/`ExpiredTokenException`으로 대체된다.[^d-assumerole-pi] **두 패턴 모두 CloudTrail data plane event 비활성화 환경에서는 `AssumeRoleForPodIdentity` event 가시성이 제한될 수 있음 — 확인 필요** (EKS Auth API event의 CloudTrail 카테고리/추적 옵션).

### D.8 — "transitive session tag는 어떻게 활용하면 좋나요? 6개 다 써야 하나요?"

Pod Identity가 부착하는 6개 session tag는 **모두 transitive**다.[^d-pod-id-abac] **"All of the session tags that are added by EKS Pod Identity are transitive; the tag keys and values are passed to any AssumeRole actions that your workloads use to switch roles into another account"**.[^d-pod-id-abac] 따라서 cross-account chaining 후에도 target 계정 리소스 정책에서 `aws:PrincipalTag/kubernetes-namespace` 같은 조건을 그대로 평가할 수 있다. **6개 다 쓸 필요는 없다**. 베스트 프랙티스 가이드는 안전한 ABAC 조건의 최소 조합으로 **`eks-cluster-arn` + `kubernetes-namespace` + `kubernetes-service-account` 세 개를 동시에 검사**할 것을 권한다.[^bp-pi-abac] 이유: namespace나 service account는 cluster 간/account 간 동일 이름이 존재할 수 있어 단독 사용 시 우회 가능하다.[^bp-pi-abac] cluster ARN까지 함께 비교해야 안전하다. `kubernetes-pod-name`/`pod-uid`는 Pod 단위 고유값이라 정책 작성에는 부적합 (rolling 시 매번 바뀜). 권장 조합: cluster ARN + namespace + SA의 3-tag.

### D.9 — "GitOps/IaC에서 association을 어떻게 관리하나요?"

association은 EKS API 리소스이므로 **선언형 관리가 전제로 설계되어 있다**.[^d-create-pi-api] 주요 옵션:

- **eksctl**: `iam.podIdentityAssociations` 필드로 namespace/SA/roleArn을 YAML 선언, `eksctl utils migrate-to-pod-identity`로 IRSA 일괄 마이그레이션 지원.[^d-eksctl-pi]
- **Terraform**: `aws_eks_pod_identity_association` resource (provider AWS ≥ 5.29.0).
- **CloudFormation / CDK**: `AWS::EKS::PodIdentityAssociation`.[^cross-account-blog]
- **AWS Controllers for Kubernetes (ACK)**: EKS controller로 Kubernetes CRD 형태로 association 선언 가능.[^cross-account-blog]
- **EKS Add-on auto-apply**: `addonsConfig.autoApplyPodIdentityAssociations: true`로 add-on 설치 시 association 자동 생성.[^d-eksctl-pi]

ArgoCD GitOps 운영 시에는 ACK나 Terraform-managed 방식이 자연스럽다(ACK는 cluster-internal CRD라 ArgoCD sync 대상 그대로). eksctl YAML은 cluster-bootstrap 단계에 적합하고 day-2 변경은 Terraform/ACK가 낫다. **eventual consistency**(association 생성 후 수 초 지연)는 모든 도구 공통 주의점이다.[^d-pod-id-limits] 도구별 선언 예시는 부록 F 참고.

### D.10 — "전환 후 IRSA로 롤백 가능한가요? dual-trust 패턴 안전한가요?"

**Credential provider chain 우선순위 덕분에 안전하게 dual-trust 운영이 가능하다.** 공식 문서: **"EKS Pod Identities have been added to the Container credential provider which is searched in a step in the default credential chain. If your workloads currently use credentials that are earlier in the chain of credentials, those credentials will continue to be used even if you configure an EKS Pod Identity association for the same workload. This way you can safely migrate from other types of credentials by creating the association first, before removing the old credentials."**[^d-pod-id-howitworks] 즉 IRSA가 chain에서 Container credential provider보다 앞에 있으므로, IRSA env(`AWS_WEB_IDENTITY_TOKEN_FILE`)가 살아있으면 Pod Identity association이 있어도 IRSA가 우선 사용된다. **권장 마이그레이션 순서**: (1) IAM Role의 trust policy에 IRSA용 OIDC statement와 Pod Identity용 `pods.eks.amazonaws.com` statement를 둘 다 추가(dual-trust), (2) Pod Identity association 생성, (3) Pod의 ServiceAccount annotation(`eks.amazonaws.com/role-arn`)을 제거하고 Pod 재기동 → Pod Identity로 전환, (4) 모니터링 후 문제 없으면 trust policy에서 OIDC statement 제거.[^bp-pi-trust][^d-pod-id-howitworks] 문제 발생 시 (3)단계 직전으로 SA annotation을 복구하면 즉시 IRSA로 fallback. trust policy에 두 statement를 동시 두는 것은 IAM 표준 동작이라 안전하다.[^bp-pi-trust]

### D 인용

[^bp-one-role]: <https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html>
[^d-pod-id-abac]: <https://docs.aws.amazon.com/eks/latest/userguide/pod-id-abac.html>
[^d-pod-id-limits]: <https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html>
[^eks-quotas]: <https://docs.aws.amazon.com/eks/latest/userguide/service-quotas.html>
[^auto-mode-id]: <https://docs.aws.amazon.com/eks/latest/userguide/automode.html>
[^d-agent-setup]: <https://docs.aws.amazon.com/eks/latest/userguide/pod-id-agent-setup.html>
[^cross-account-blog]: <https://aws.amazon.com/blogs/containers/amazon-eks-pod-identity-streamlines-cross-account-access/>
[^target-role]: <https://docs.aws.amazon.com/eks/latest/userguide/pod-id-assign-target-role.html>
[^d-pod-id-howitworks]: <https://docs.aws.amazon.com/eks/latest/userguide/pod-id-how-it-works.html>
[^bp-irsa-token]: <https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html>
[^d-assumerole-pi]: <https://docs.aws.amazon.com/eks/latest/APIReference/API_auth_AssumeRoleForPodIdentity.html>
[^session-tags-ctlogs]: <https://docs.aws.amazon.com/IAM/latest/UserGuide/id_session-tags.html>
[^bp-pi-abac]: <https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html>
[^d-create-pi-api]: <https://docs.aws.amazon.com/eks/latest/APIReference/API_PodIdentityAssociation.html>
[^d-eksctl-pi]: <https://docs.aws.amazon.com/eks/latest/eksctl/pod-identity-associations.html>
[^bp-pi-trust]: <https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html>

---

## 부록 E — 운영/디버깅 플레이북

각 시나리오: 증상 → 원인 가설 → 진단 명령 → 해결 → AWS 공식 출처.

### E.1 — Pod가 자격증명을 못 받는다 (`The security token included in the request is invalid` / `NoCredentialProviders`)

**증상**

Pod 안에서 `aws sts get-caller-identity`가 `NoCredentialProviders: no valid providers in chain` 또는 `The security token included in the request is invalid`를 반환한다. SDK는 default credential chain을 끝까지 훑고도 EKS Pod Identity Agent에서 자격증명을 받아오지 못한 상태다.[^e-pi-howitworks]

**원인 가설**

- Pod Identity association이 해당 namespace/ServiceAccount에 만들어지지 않았다.
- SDK 버전이 container credential provider를 지원하지 않는다 (Boto3 ≥ 1.34.41, Go v2 ≥ 2023-11-14, Java v2 ≥ 2.21.30 등).[^e-pi-sdk]
- Pod 매니페스트에 IRSA의 `AWS_WEB_IDENTITY_TOKEN_FILE` env가 먼저 잡혀 chain에서 IRSA가 우선 선택되었다 (Pod Identity는 chain에 추가될 뿐이며 더 앞 단계에서 자격증명이 발견되면 그것이 사용된다).[^e-pi-howitworks]
- `eks-pod-identity-agent` DaemonSet pod가 해당 노드에서 죽어 있다.

**진단 명령**

```bash
# 1) Association 존재 여부
aws eks list-pod-identity-associations \
  --cluster-name <cluster-blue> \
  --namespace <ns> --service-account <sa>

# 2) Pod에 환경변수가 주입됐는지 (주입되면 Pod Identity 경로, 없으면 association 누락 또는 Pod 미재시작)
kubectl get pod <pod> -o jsonpath='{.spec.containers[*].env}' | tr ',' '\n' | grep -E 'AWS_CONTAINER_(CREDENTIALS_FULL_URI|AUTHORIZATION_TOKEN_FILE)'

# 3) 같은 노드의 agent pod 상태/로그
NODE=$(kubectl get pod <pod> -o jsonpath='{.spec.nodeName}')
kubectl -n kube-system get pod -l app.kubernetes.io/name=eks-pod-identity-agent --field-selector spec.nodeName=$NODE
kubectl -n kube-system logs -l app.kubernetes.io/name=eks-pod-identity-agent --field-selector spec.nodeName=$NODE --tail=200

# 4) SDK debug log (Python 예시)
AWS_LOG_LEVEL=debug python -c "import boto3; print(boto3.client('sts').get_caller_identity())"
```

**해결**

1. Association이 없으면 생성하고 Pod를 재시작한다 (`AWS_CONTAINER_CREDENTIALS_FULL_URI` env는 Pod 시작 시점에만 주입된다).[^e-pi-howitworks]
2. SDK 최소 버전을 컨테이너 이미지 기준으로 올린다.[^e-pi-sdk]
3. IRSA env가 남아 있으면 ServiceAccount의 `eks.amazonaws.com/role-arn` annotation을 제거하고 Pod를 재시작한다 (E.6 참고).
4. Agent 로그가 `AssumeRoleForPodIdentity` 실패를 보이면 노드 IAM role 권한을 확인한다 (E.2 참고).

**출처**

[^e-pi-howitworks][^e-pi-sdk]

### E.2 — Agent CrashLoopBackOff / NotReady

**증상**

`kubectl -n kube-system get ds eks-pod-identity-agent`의 READY가 노드 수보다 작다. 개별 pod는 `CrashLoopBackOff`이거나 `Running`이지만 readiness probe가 실패한다.

**원인 가설**

- 노드 IAM role에 `eks-auth:AssumeRoleForPodIdentity` 권한이 없다 (`AmazonEKSWorkerNodePolicy` 미부착 또는 자체 정책 누락).[^e-pi-agent-setup]
- 노드에서 IPv6가 비활성화되어 있는데 agent가 기본값으로 `[fd00:ec2::23]` 바인딩을 시도한다.[^e-pi-considerations]
- 같은 노드에 hostNetwork로 port 80/2703을 점유하는 다른 워크로드가 있다.[^e-pi-considerations]
- EKS Auth API에 도달할 수 없다 (private cluster, E.3 참고).[^e-pi-agent-setup]

**진단 명령**

```bash
kubectl -n kube-system describe ds eks-pod-identity-agent
kubectl -n kube-system logs ds/eks-pod-identity-agent --tail=200

# 노드 IAM role 권한 확인 (관리형 노드그룹)
aws eks describe-nodegroup --cluster-name <cluster-blue> --nodegroup-name <ng> \
  --query 'nodegroup.nodeRole'
aws iam list-attached-role-policies --role-name <node-role>

# probe (agent 컨테이너는 :2703/healthz, :2703/readyz 사용)
kubectl -n kube-system exec ds/eks-pod-identity-agent -- wget -qO- http://127.0.0.1:2703/readyz
```

**해결**

1. 노드 IAM role에 `AmazonEKSWorkerNodePolicy`를 attach하거나 `eks-auth:AssumeRoleForPodIdentity` 단일 권한을 가진 인라인 정책을 추가한다.[^e-pi-agent-setup]
2. IPv6를 못 쓰는 노드에서는 add-on `configurationValues`로 `{"agent":{"additionalArgs":{"-b":"169.254.170.23"}}}`를 설정해 IPv4-only로 바인딩한다.[^e-pi-ipv6]
3. 변경 후 `kubectl rollout status daemonset/eks-pod-identity-agent -n kube-system`로 롤아웃을 확인한다.[^e-pi-ipv6]

**출처**

[^e-pi-agent-setup][^e-pi-considerations][^e-pi-ipv6]

### E.3 — Private cluster: `eks-auth` PrivateLink 누락

**증상**

Public NAT가 없거나 VPC가 격리된 private subnet에서 agent 로그에 `i/o timeout` 또는 `dial tcp ... eks-auth.<region>.api.aws:443: connect`가 반복된다. Pod는 자격증명을 받지 못한다. AWS 공식 가이드는 private subnet 노드의 경우 EKS Auth API용 PrivateLink interface endpoint가 **반드시** 필요하다고 명시한다.[^e-pi-agent-setup]

**진단 명령**

```bash
# DNS 해석 확인 (노드 또는 디버그 Pod에서)
kubectl -n kube-system debug node/<node> -it --image=public.ecr.aws/amazonlinux/amazonlinux:2 -- bash -c 'dig +short eks-auth.<region>.api.aws; dig +short eks-auth.<region>.amazonaws.com'

# eks-auth endpoint 존재 여부
aws ec2 describe-vpc-endpoints \
  --filters Name=service-name,Values=com.amazonaws.<region>.eks-auth \
  --query 'VpcEndpoints[].{id:VpcEndpointId,state:State,subnets:SubnetIds,sg:Groups}'

# endpoint SG가 노드 CIDR로부터 443 인바운드 허용하는지
aws ec2 describe-security-groups --group-ids <eks-auth-endpoint-sg> \
  --query 'SecurityGroups[].IpPermissions'
```

**해결**

1. EKS Auth API용 interface endpoint를 만든다.

   ```bash
   aws ec2 create-vpc-endpoint \
     --vpc-id <vpc-id> --vpc-endpoint-type Interface \
     --service-name com.amazonaws.<region>.eks-auth \
     --subnet-ids <subnet-a> <subnet-b> \
     --security-group-ids <eks-auth-endpoint-sg> \
     --private-dns-enabled
   ```

2. endpoint SG에 노드 SG로부터 TCP 443 인바운드를 허용한다.
3. private DNS가 켜져 있어야 `eks-auth.<region>.api.aws` 기본 이름이 endpoint로 라우팅된다 (VPC `enableDnsHostnames`/`enableDnsSupport` 필요).[^e-eks-privatelink]

**출처**

[^e-pi-agent-setup][^e-eks-privatelink]

### E.4 — Proxy 환경: `no_proxy` 누락

**증상**

http(s) proxy를 강제하는 클러스터에서 Pod 첫 호출 시 자격증명 획득이 timeout된다. SDK가 `http://169.254.170.23/v1/credentials`를 proxy로 보내려다 실패한다. 공식 가이드는 proxy 사용 시 `169.254.170.23`(IPv4)와 `[fd00:ec2::23]`(IPv6)을 `no_proxy/NO_PROXY`에 추가하라고 명시한다.[^e-pi-considerations]

**진단 명령**

```bash
# Pod의 proxy env 확인
kubectl exec <pod> -- env | grep -iE '^(http|https|no)_proxy'

# 자격증명 endpoint 직접 호출 (Pod 내부)
kubectl exec <pod> -- sh -c 'curl -sS -H "Authorization: $(cat $AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE)" $AWS_CONTAINER_CREDENTIALS_FULL_URI | head -c 200'
```

**해결**

PodSpec env 또는 namespace-level injector(예: `kube-environment-injector` 같은 mutating webhook)에 다음을 추가한다.

```yaml
env:
  - name: NO_PROXY
    value: "169.254.170.23,[fd00:ec2::23],169.254.169.254,.svc,.cluster.local,10.0.0.0/8"
  - name: no_proxy
    value: "169.254.170.23,[fd00:ec2::23],169.254.169.254,.svc,.cluster.local,10.0.0.0/8"
```

cluster-wide containerd HTTP proxy를 쓰는 경우 노드 단위 `/etc/systemd/system/containerd.service.d/http-proxy.conf`의 `NO_PROXY`도 동일하게 갱신한다.

**출처**

[^e-pi-considerations]

### E.5 — Cross-account: confused-deputy 방지 (`externalId`)

**증상**

`targetRoleArn`을 사용한 cross-account 접근 시, 다른 cluster/namespace의 ServiceAccount가 같은 source-account의 EKS Pod Identity role을 거쳐 동일한 target role을 assume할 수 있다. trust policy가 source account의 root만 신뢰하면 confused deputy가 성립한다.[^confused-deputy]

**원인**

cross-account 호출은 EKS Auth가 **role chaining** (Pod Identity role → target role)으로 처리한다. session tag를 활성화한 기본 모드에서는 EKS Auth가 `eks-cluster-arn`/`kubernetes-namespace`/`kubernetes-service-account`를 transitive session tag로 붙인다. session tag를 비활성화한 경우 EKS Pod Identity는 `sts:ExternalId`를 `region/account/cluster-name/namespace/service-account-name` 형식으로 넣는다.[^e-pi-target-role]

**진단 명령**

```bash
# Target role의 trust policy 확인
aws iam get-role --role-name <target-role> --query Role.AssumeRolePolicyDocument

# CloudTrail에서 cross-account AssumeRole 호출 검사
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole \
  --max-results 20 \
  --query 'Events[?contains(Resources[].ResourceName,`<target-role>`)]'
```

**해결**

trust policy에 cluster·namespace·SA를 고정하는 조건을 강제한다. session tag가 켜져 있을 때:

```json
{
  "Effect": "Allow",
  "Principal": {"AWS": "arn:aws:iam::<source-acct>:root"},
  "Action": ["sts:AssumeRole","sts:TagSession"],
  "Condition": {
    "StringEquals": {
      "aws:RequestTag/eks-cluster-arn": "arn:aws:eks:<region>:<source-acct>:cluster/cluster-blue",
      "aws:RequestTag/kubernetes-namespace": "<ns>",
      "aws:RequestTag/kubernetes-service-account": "<sa>"
    },
    "ArnEquals": {
      "aws:PrincipalArn": "arn:aws:iam::<source-acct>:role/eks-pod-identity-primary-role"
    }
  }
}
```

session tag를 끈 경우 `sts:ExternalId`로 동일 의미를 강제한다 (값 형식은 위 원인 참고).[^e-pi-target-role]

**출처**

[^e-pi-target-role][^confused-deputy]

### E.6 — 마이그레이션 후 여전히 IRSA 동작 (annotation 미제거)

**증상**

Pod Identity association을 만들었는데 CloudTrail에는 `AssumeRoleWithWebIdentity`가 계속 찍히고 `AssumeRoleForPodIdentity`는 안 보인다. SDK가 chain 앞단의 IRSA web identity를 먼저 잡고 멈추기 때문이다.[^e-pi-howitworks]

**진단 명령**

```bash
# ServiceAccount에 IRSA annotation이 남아 있는지
kubectl get sa <sa> -n <ns> -o jsonpath='{.metadata.annotations}'

# Pod env에서 IRSA token mount 확인
kubectl get pod <pod> -o jsonpath='{.spec.containers[*].env}' | tr ',' '\n' \
  | grep -E 'AWS_(WEB_IDENTITY_TOKEN_FILE|ROLE_ARN|CONTAINER_CREDENTIALS_FULL_URI)'

# CloudTrail 분포 비교 (최근 1시간)
aws cloudtrail lookup-events \
  --start-time $(date -u -v-1H +%FT%TZ) \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --max-results 50 --query 'length(Events)'
aws cloudtrail lookup-events \
  --start-time $(date -u -v-1H +%FT%TZ) \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleForPodIdentity \
  --max-results 50 --query 'length(Events)'
```

**해결**

1. ServiceAccount의 `eks.amazonaws.com/role-arn` annotation을 제거한다.[^e-pi-association]
2. Pod를 재생성한다 (env는 Pod admission 시점에 주입되며 in-place update가 안 된다).[^e-pi-howitworks]
3. 점진 마이그레이션 중이면 IRSA env를 가진 Pod와 Pod Identity Pod를 라벨로 분리하고, CloudTrail로 두 이벤트의 비율이 100%로 넘어가는지 추적한다.

**출처**

[^e-pi-howitworks][^e-pi-association]

### E.7 — ABAC 조건이 작동 안 함 (transitive 누락 / packed policy 한도)

**증상**

target role 또는 resource policy에서 `aws:PrincipalTag/eks-cluster-arn` 조건이 false로 평가되어 `AccessDenied`가 발생한다. 또는 Pod 시작 시 `PackedPolicyTooLarge` 에러로 자격증명 발급 자체가 실패한다.[^e-pi-abac]

**원인 가설**

- 워크로드가 SDK 안에서 추가로 `sts:AssumeRole`을 호출(role chaining)하면서 EKS Pod Identity가 붙인 session tag를 transitive로 넘기지 않았다 — Pod Identity가 붙이는 tag 자체는 transitive지만, 사용자 코드가 다시 chain할 때 `--transitive-tag-keys`를 명시하지 않으면 다음 세션에 안 넘어간다.[^e-pi-abac][^e-iam-session-tags]
- Pod Identity 기본 session tag 6개 + 사용자 inline session policy + role policy ARN의 합이 packed binary 한도를 초과했다 (`PackedPolicyTooLarge`).[^e-pi-abac]

**진단 명령**

```bash
# 어떤 tag가 실제로 세션에 들어갔는지 (Pod 안에서)
kubectl exec <pod> -- aws sts get-caller-identity --debug 2>&1 | grep -i tag

# 정책 시뮬레이션 (외부 계정에서 target role 기준)
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::<acct>:role/<target-role> \
  --action-names s3:GetObject \
  --resource-arns arn:aws:s3:::<bucket>/* \
  --context-entries ContextKeyName=aws:PrincipalTag/eks-cluster-arn,ContextKeyType=string,ContextKeyValues=arn:aws:eks:<region>:<acct>:cluster/cluster-blue
```

**해결**

1. user-side `AssumeRole` 호출에 `--transitive-tag-keys eks-cluster-arn,kubernetes-namespace,kubernetes-service-account`를 명시한다.[^e-iam-session-tags]
2. `PackedPolicyTooLarge`가 뜨면 Pod Identity association에서 **Disable session tags**를 켜고 필요한 tag만 IAM role에 직접 attach해 `aws:PrincipalTag/...`로 참조한다 — Pod Identity가 IAM role tag도 동일 키 형식으로 노출한다.[^e-pi-abac]
3. session policy를 줄이거나 권한을 별도 role로 분리한다.

**출처**

[^e-pi-abac][^e-iam-session-tags]

### E.8 — Agent 헬스 체크 / probe port 진단

**증상**

agent pod는 `Running`인데 readiness probe가 실패해 NotReady로 떨어진다. 동일 노드의 워크로드 Pod가 자격증명 endpoint(`169.254.170.23:80`)에 연결을 못 한다.

**진단 명령**

agent의 health probe는 hostNetwork에서 port `2703`을 사용하며, liveness는 `/healthz`, readiness는 `/readyz` 경로다. 자격증명 발급은 link-local IP의 port `80`을 통해 이뤄진다.[^e-pi-considerations][^e-pi-agent-helm]

```bash
# 노드 셸에서 직접 probe (디버그 Pod)
kubectl debug node/<node> -it --image=public.ecr.aws/amazonlinux/amazonlinux:2 -- \
  sh -c 'curl -fsS http://127.0.0.1:2703/healthz; echo; curl -fsS http://127.0.0.1:2703/readyz'

# 자격증명 endpoint 응답 (hostNetwork agent에 직접)
kubectl debug node/<node> -it --image=public.ecr.aws/amazonlinux/amazonlinux:2 -- \
  curl -sS -o /dev/null -w '%{http_code}\n' http://169.254.170.23/v1/credentials

# probe 실패 원인 — describe로 lastState/exitCode 확인
kubectl -n kube-system describe pod -l app.kubernetes.io/name=eks-pod-identity-agent --field-selector spec.nodeName=<node>
```

**해결**

1. `/readyz`가 503이면 agent 로그에서 `AssumeRoleForPodIdentity` 호출 실패(노드 role 권한, eks-auth 도달 불가)를 우선 본다 (E.2/E.3).
2. port 2703이 다른 hostNetwork 워크로드와 충돌하면 충돌 워크로드를 옮긴다 (agent는 system-node-critical로 우선순위가 높지만 port 충돌은 별개).[^e-pi-considerations]
3. 헬스 체크 자체는 정상인데 워크로드 Pod 호출이 실패하면 NetworkPolicy가 link-local IP 트래픽을 차단했는지 확인한다 (eBPF/Cilium NetworkPolicy 환경에서 빈번).

**출처**

[^e-pi-considerations][^e-pi-agent-helm]

### E 인용

[^e-pi-howitworks]: <https://docs.aws.amazon.com/eks/latest/userguide/pod-id-how-it-works.html>
[^e-pi-sdk]: <https://docs.aws.amazon.com/eks/latest/userguide/pod-id-minimum-sdk.html>
[^e-pi-agent-setup]: <https://docs.aws.amazon.com/eks/latest/userguide/pod-id-agent-setup.html>
[^e-pi-considerations]: <https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html>
[^e-pi-ipv6]: <https://docs.aws.amazon.com/eks/latest/userguide/pod-id-agent-config-ipv6.html>
[^e-eks-privatelink]: <https://docs.aws.amazon.com/eks/latest/userguide/vpc-interface-endpoints.html>
[^e-pi-target-role]: <https://docs.aws.amazon.com/eks/latest/userguide/pod-id-assign-target-role.html>
[^confused-deputy]: <https://docs.aws.amazon.com/IAM/latest/UserGuide/confused-deputy.html>
[^e-pi-association]: <https://docs.aws.amazon.com/eks/latest/userguide/pod-id-association.html>
[^e-pi-abac]: <https://docs.aws.amazon.com/eks/latest/userguide/pod-id-abac.html>
[^e-iam-session-tags]: <https://docs.aws.amazon.com/IAM/latest/UserGuide/id_session-tags.html>
[^e-pi-agent-helm]: <https://github.com/aws/eks-pod-identity-agent> (charts/eks-pod-identity-agent/values.yaml — `agent.probePort: 2703`, `livenessEndpoint: /healthz`, `readinessEndpoint: /readyz`. AWS 공식 user-guide에는 probe path 명시가 없으므로 agent repo의 Helm chart values를 참조함; 확인 필요 시 `kubectl -n kube-system get ds eks-pod-identity-agent -o yaml`로 실제 probe 정의를 확인.)

---

## 부록 F — 마이그레이션 자동화 패턴

이 부록은 Pod Identity Association을 코드로 관리하기 위한 도구별 패턴과, blue/green 시나리오에서 association lifecycle을 어떻게 다룰지 정리한다. 각 도구는 동일한 EKS API(`CreatePodIdentityAssociation`)를 호출하므로[^eks-api-create] 결과 리소스는 동일하지만, 선언 모델·drift 처리·GitOps 적합도가 달라 사용처가 갈린다.

### F.1 — eksctl `ClusterConfig` (선언형)

`eksctl`은 `iam.podIdentityAssociations` 필드로 association을 ClusterConfig 안에서 선언적으로 관리한다.[^f-eksctl-pi] 사전 조건으로 `eks-pod-identity-agent` addon이 클러스터에 설치돼 있어야 하며, 이 또한 `addons:` 블록에 추가하면 자동 설치된다.[^f-eksctl-pi] 필수 필드는 `namespace`, `serviceAccountName`이고, IAM 측은 `roleARN`을 직접 지정하거나 `permissionPolicyARNs`/`permissionPolicy`/`wellKnownPolicies` 중 하나로 자동 role 생성을 위임할 수 있다 (상호 배타).[^f-eksctl-pi] `eksctl create podidentityassociation -f config.yaml`로 cluster 생성 후에도 동일 파일로 reconcile 가능하다.[^f-eksctl-pi]

```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: cluster-blue
  region: ap-northeast-2

addons:
- name: eks-pod-identity-agent

iam:
  podIdentityAssociations:
  - namespace: team-A
    serviceAccountName: service-A
    roleARN: arn:aws:iam::123456789012:role/role-app-name
  - namespace: team-A
    serviceAccountName: service-B
    permissionPolicyARNs:
    - arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess
```

### F.2 — Terraform `aws_eks_pod_identity_association`

Terraform AWS provider는 v5.29.0부터 `aws_eks_pod_identity_association` 리소스를 제공한다.[^f-tf-pi-issue] 필수 인자는 `cluster_name`, `namespace`, `service_account`, `role_arn`이며, 옵션으로 `disable_session_tags`, `target_role_arn`, `tags`가 있다.[^f-tf-pi] export 속성으로 `association_arn`, `association_id`, `external_id`(target role chaining 시 trust policy condition에 사용)을 제공한다.[^f-tf-pi] `cluster_name`/`namespace`/`service_account`는 변경 시 replacement가 필요하므로 SA 이름 변경은 신중히 다룬다 (이 동작은 동일 키를 갖는 CloudFormation resource와 일치).[^f-cfn-pi]

```hcl
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.29.0" }
  }
}

resource "aws_eks_pod_identity_association" "service_a" {
  cluster_name    = "cluster-blue"
  namespace       = "team-A"
  service_account = "service-A"
  role_arn        = "arn:aws:iam::123456789012:role/role-app-name"

  tags = {
    ManagedBy = "terraform"
    Team      = "team-A"
  }
}
```

### F.3 — AWS Controllers for Kubernetes (ACK)

ACK `eks-controller`는 GA 상태이며 `PodIdentityAssociation`을 정식 CRD로 지원한다 (community 문서 기준 RELEASED / GENERAL AVAILABILITY, 1.13.0).[^f-ack-eks-status] CRD는 `eks.services.k8s.aws/v1alpha1` 그룹에 속하며 spec 필드는 EKS API와 1:1 매핑된다 (`clusterName`, `namespace`, `serviceAccount`, `roleARN`, `targetRoleARN`, `policy`, `disableSessionTags`, `tags`).[^f-ack-eks-pi] `clusterRef`/`roleRef`로 ACK가 관리하는 다른 CR(예: `Cluster`, IAM controller의 `Role`)을 참조하면 ARN을 하드코딩하지 않아도 된다.[^f-ack-eks-pi] GitOps 관점에서는 association 자체를 K8s 리소스로 다룰 수 있다는 게 가장 큰 장점이다 (F.7 참조).

```yaml
apiVersion: eks.services.k8s.aws/v1alpha1
kind: PodIdentityAssociation
metadata:
  name: service-a-association
  namespace: ack-system
spec:
  clusterName: cluster-blue
  namespace: team-A
  serviceAccount: service-A
  roleARN: arn:aws:iam::123456789012:role/role-app-name
  tags:
    ManagedBy: ack
```

### F.4 — CloudFormation `AWS::EKS::PodIdentityAssociation`

CloudFormation도 동일한 resource type을 1급으로 제공한다. 필수 속성은 `ClusterName`, `Namespace`, `ServiceAccount`, `RoleArn`이고, 옵션은 `DisableSessionTags`, `Policy`(escaped JSON 인라인 정책), `TargetRoleArn`, `Tags`이다.[^f-cfn-pi] `Fn::GetAtt`로 `AssociationArn`, `AssociationId`, `ExternalId`을 노출한다.[^f-cfn-pi] `ClusterName`/`Namespace`/`ServiceAccount`는 update 시 replacement, 나머지는 no-interruption update이다.[^f-cfn-pi]

```yaml
Resources:
  ServiceAAssociation:
    Type: AWS::EKS::PodIdentityAssociation
    Properties:
      ClusterName: cluster-blue
      Namespace: team-A
      ServiceAccount: service-A
      RoleArn: !Sub arn:aws:iam::${AWS::AccountId}:role/role-app-name
      Tags:
        - Key: ManagedBy
          Value: cloudformation
```

### F.5 — Pulumi

Pulumi의 `aws.eks.PodIdentityAssociation`은 Terraform과 동일한 매핑을 따른다. 필수 인자는 `clusterName`, `namespace`, `serviceAccount`, `roleArn`이고, 옵션은 `disableSessionTags`, `targetRoleArn`, `tags`이다.[^f-pulumi-pi] 출력값으로 `associationArn`, `associationId`, `externalId`이 제공된다.[^f-pulumi-pi]

```python
import pulumi_aws as aws

aws.eks.PodIdentityAssociation("service-a",
    cluster_name="cluster-blue",
    namespace="team-A",
    service_account="service-A",
    role_arn="arn:aws:iam::123456789012:role/role-app-name",
    tags={"ManagedBy": "pulumi"})
```

### F.6 — Blue/Green 마이그레이션 lifecycle 자동화

Pod Identity의 핵심 장점은 IAM role이 OIDC issuer에 묶이지 않아 동일 role을 여러 클러스터에서 재사용할 수 있다는 점이다.[^f-eksctl-pi][^f-pi-overview] 이 덕에 blue/green 클러스터 마이그레이션은 다음 lifecycle로 단순해진다:

1. **green에 association 추가** — 동일 `(namespace, serviceAccount, roleArn)` 조합을 green 클러스터에 신규 association으로 만든다. 같은 role이 여러 association에서 동시에 사용돼도 무방하다.
2. **트래픽 점진 전환** — Route53 weighted record / external LB 가중치 / ArgoCD ApplicationSet 등으로 워크로드를 green으로 이동.
3. **검증 후 blue association 삭제** — green이 안정화되면 blue에서 association만 삭제. role은 그대로 둔다 (green이 계속 사용 중).

도구별 권장 구성:

- **Terraform**: 클러스터별 workspace 또는 module instance 분리 (`cluster_name = "cluster-blue"` vs `"cluster-green"`). 동일 role ARN을 두 workspace의 변수로 주입해 중복 정의 회피. blue 폐기 단계는 `terraform destroy -target=...` 또는 module 제거 + `terraform apply`.
- **eksctl**: 클러스터당 ClusterConfig 파일 1개 (`cluster-blue.yaml`, `cluster-green.yaml`). `eksctl create/update/delete podidentityassociation -f`가 idempotent하므로 CI에서 동일 명령을 재실행해도 안전.[^f-eksctl-pi]
- **ACK**: 각 클러스터 안에 자기 자신의 association CR을 두는 패턴이 가장 깔끔 (F.7).
- **CloudFormation**: 클러스터별 stack 또는 nested stack 분리. drift detection으로 수동 변경 감지.

생성 → 트래픽 전환 → 삭제 단계는 **생성 단계는 ACK/eksctl/Terraform 중 팀 표준**으로, **삭제 단계는 변경 추적이 명확한 IaC(Terraform/CloudFormation)**로 다루는 분리도 실무에서 자주 쓴다 (누가 무엇을 지웠는지 audit이 쉬움). 단, 도구를 섞으면 ownership이 모호해지므로 association 단위 ownership 라벨/태그(`ManagedBy=...`)를 강제하는 것을 권장한다.

### F.7 — GitOps 통합 패턴 (ArgoCD/Flux + ACK)

ACK가 GitOps와 가장 자연스러운 이유는 association이 클러스터 안의 K8s 리소스로 표현되기 때문이다.[^f-ack-eks-pi] ArgoCD/Flux가 다른 워크로드 매니페스트를 동기화하듯 `PodIdentityAssociation` CR도 동일 sync loop에서 reconcile되며, drift는 cluster controller가 아니라 ACK controller가 EKS API로 수정한다.

권장 레포 구조:

```
gitops/
├── cluster-blue/
│   ├── apps/...
│   └── pod-identity/
│       ├── team-A-service-A.yaml   # ACK PodIdentityAssociation
│       └── team-A-service-B.yaml
└── cluster-green/
    └── pod-identity/
        ├── team-A-service-A.yaml
        └── team-A-service-B.yaml
```

각 클러스터의 ArgoCD가 자신의 디렉터리만 watch하므로 blue/green 동시 운영 중에도 association 정의가 분리된다. PR 한 번으로 green에 association을 추가하고, 검증 후 두 번째 PR로 blue 디렉터리에서 삭제하는 흐름이 audit·rollback 양쪽에 유리하다. 단, ACK controller 자체의 IRSA(또는 Pod Identity) 권한이 `eks:CreatePodIdentityAssociation`, `eks:DeletePodIdentityAssociation`, `iam:PassRole`을 포함해야 한다 (생성자 IAM principal에 `iam:PassRole` 필요).[^f-pi-userguide]

### F.8 — IRSA → Pod Identity 점진 전환 자동화 (3-step의 도구별 매핑)

Section 5에서 정의한 3-step (① association 생성 → ② SA의 IRSA annotation 제거 → ③ role trust policy 정리)을 도구별로 매핑한다.

| Step | Terraform | eksctl | ACK | CloudFormation |
|---|---|---|---|---|
| ① association 생성 | `aws_eks_pod_identity_association` 추가 후 `apply`[^f-tf-pi] | `iam.podIdentityAssociations`에 추가 + `eksctl create podidentityassociation -f`[^f-eksctl-pi] | `PodIdentityAssociation` CR PR merge | `AWS::EKS::PodIdentityAssociation` 추가 후 stack update[^f-cfn-pi] |
| ② SA annotation 제거 | `kubernetes_service_account`의 `eks.amazonaws.com/role-arn` annotation 제거 + 워크로드 rollout | manifest/Helm chart에서 annotation 제거 | Kustomize/Helm overlay에서 annotation 제거 후 ArgoCD sync | 별도 K8s 매니페스트 변경 (CFN 범위 밖) |
| ③ trust policy 정리 | `aws_iam_role.assume_role_policy`에서 OIDC federated statement 삭제[^f-pi-userguide] | 외부 IAM 관리 (eksctl 범위 밖) | ACK iam-controller의 `Role` CR로 관리 시 spec 수정 | role을 CFN으로 관리 중이면 `AssumeRolePolicyDocument` 갱신 |

CI/CD로 묶을 때는 단계 사이에 **검증 게이트**를 둔다. ① 후에는 새 Pod에서 `AWS_CONTAINER_CREDENTIALS_FULL_URI` 환경변수가 주입되는지 확인,[^f-pi-overview] ② 후에는 IRSA token 파일 경로 (`AWS_WEB_IDENTITY_TOKEN_FILE`) 의존이 끊겼는지 dry-run, ③ 직전에는 CloudTrail에서 해당 role의 `AssumeRoleWithWebIdentity` 호출이 일정 기간 (예: 7일) 0건임을 확인. 이 흐름을 Argo Workflows / GitHub Actions matrix(클러스터별)로 자동화하면 blue/green 두 클러스터에 대해 동일 procedure를 병렬 적용할 수 있다.

### F 인용

[^f-eksctl-pi]: <https://docs.aws.amazon.com/eks/latest/eksctl/pod-identity-associations.html>
[^f-tf-pi]: <https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association>
[^f-tf-pi-issue]: <https://github.com/terraform-aws-modules/terraform-aws-eks/issues/2850>
[^f-ack-eks-pi]: <https://aws-controllers-k8s.github.io/community/reference/eks/v1alpha1/podidentityassociation/>
[^f-ack-eks-status]: <https://aws-controllers-k8s.github.io/community/docs/community/services/>
[^f-cfn-pi]: <https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-eks-podidentityassociation.html>
[^f-pulumi-pi]: <https://www.pulumi.com/registry/packages/aws/api-docs/eks/podidentityassociation/>
[^eks-api-create]: <https://docs.aws.amazon.com/eks/latest/APIReference/API_CreatePodIdentityAssociation.html>
[^f-pi-userguide]: <https://docs.aws.amazon.com/eks/latest/userguide/pod-id-association.html>
[^f-pi-overview]: <https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html>
