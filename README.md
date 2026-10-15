# DangCharge_GitOps
당충전 서비스 쿠버네티스 배포 매니페스트 및 GitOps 저장소

## query-api 배포 준비

- consumer `develop`의 `fe7187338c7bf35649aee5311656c3aeb74ae905` 설정을 기준으로 작성했다.
- Jenkins가 `ghcr.io/pika-chew/dangcharge-be-consumer` 이미지를 push하고
  `manifests/workloads/query-api/kustomization.yaml`의 `newTag`를 실제 커밋 태그로
  갱신해야 한다. `replace-me-commit-tag` 상태에서는 Sync하지 않는다.
- `dangcharge` 네임스페이스의 `mongodb-app` Secret에 `MONGODB_URI`가 필요하다.
  기존 `scripts/mongodb/create-secrets.sh`가 생성하는 키이며, 기존 Secret은 재생성하지 않는다.
- 같은 네임스페이스의 `consumer-secrets` Secret에 `JWT_PUBLIC_KEY`를 준비한다.
  producer가 발급하는 JWT와 같은 키 쌍의 X.509 RSA 공개키(PEM 또는 Base64)를 사용한다.
  개인키는 consumer에 전달하지 않는다. Secret 값은 Git에 저장하지 않는다.
- Kafka는 인접 `DangCharge_Infra`의 inventory와 Kafka 역할 설정 기준
  `10.10.0.32:9092`(PLAINTEXT)이다. 실제 배포 환경 및 Pod에서의 연결 가능 여부를 확인한다.
  그룹은 앱 기본값인 `dangcharge-consumer`이며, 새 그룹은 `earliest`부터 읽는다.
  `dangcharge.user`, `dangcharge.station`, `dangcharge.reservation`과 각각의 `.DLT`
  토픽 준비 및 소비·DLT 발행 권한을 확인한다.
- GHCR 패키지가 비공개라면 `imagePullSecrets`를 먼저 구성한다.

이미지·Secret·MongoDB/Kafka 준비를 확인한 뒤 `bootstrap/root-app.yaml`의 query-api
`exclude`와 `apps/workloads/query-api.yaml`의 `skip-reconcile`을 제거한다.
변경을 main에 반영하고 root에서 Application을 등록한 다음 query-api를 수동 Sync한다.
자동 Sync는 비활성 상태다.

외부 요청 `/query/api/v1/...`는 Ingress에서 `/query`를 제거해 앱의 `/api/v1/...`로
전달한다. `SERVER_CONTEXT_PATH=/`와 Spring 표준 `SERVER_SERVLET_CONTEXT_PATH=/`를
설정하고 `SERVER_FORWARD_HEADERS_STRATEGY=framework`로 전달된 prefix를 처리한다.
Sync 후 이미지 pull, MongoDB 연결, Kafka 이벤트 반영, 공개 조회 API와 JWT 인증을 확인한다.
현재 TCP probe는 포트 개방만 검사하며 MongoDB/Kafka 준비를 보장하지 않는다.

로컬 렌더링 확인:

```sh
kubectl kustomize manifests/workloads/query-api
```
