# DangCharge_GitOps
당충전 서비스 쿠버네티스 배포 매니페스트 및 GitOps 저장소

## 프로듀서 API 라우팅

`api-routing`은 `api.dangcharge.cloud`의 다음 경로를 `dangcharge` 네임스페이스의
`command-api` Service(`http`, 8080)로 전달한다. URL 경로를 제거하거나 재작성하지 않는다.

- `/api/v1/auth`
- `/api/v1/users`
- `/api/v1/vehicle-models`
- `/api/v1/stations`
- `/api/v1/reservations`
- `/api/v1/charging`

query-api가 준비되기 전까지 위 경로의 모든 HTTP 메서드를 프로듀서로 전달한다.
라우팅 설정은 앱의 미구현 API를 구현하지 않으며, JWT 인증과 권한, CORS는 앱에서 처리한다.
관리 API(`/api/v1/admin`), Actuator, Swagger는 이 Ingress에 포함하지 않는다.
다른 Ingress나 외부 접속 경로의 접근 제어까지 보장하는 설정은 아니다.

### 연결 조건

- 외부 HTTPS는 Cloudflare에서 종료하고 origin은 `http://10.20.0.150:80`을 사용한다.
- Cloudflare는 origin 요청의 Host를 `api.dangcharge.cloud`로 전달해야 한다.
- FIP는 Traefik VIP `10.10.0.50:80`으로 연결되어 있어야 한다.
- 클러스터에 `traefik` IngressClass가 있어야 한다.
- Cloudflare, FIP, VIP 연결은 이 Ingress가 생성하거나 변경하지 않는다.

### main 반영 후 적용

1. Infra 저장소의 Ansible `argocd-bootstrap.yml`을 다시 실행해 root의 제외 설정을 갱신한다.
   root는 `apps/`를 읽으며 `bootstrap/root-app.yaml` 자체를 동기화하지 않으므로,
   Git 머지만으로 기존 root의 제외 설정이 바뀌지 않는다.
2. root가 동기화되어 `api-routing` Application이 등록됐는지 확인한다.
   `query-api`는 계속 제외한다.
3. Argo CD에서 `api-routing`만 수동 Sync한다. 최초 적용에서 별도 prune이나 force는 필요 없다.

### 적용 후 확인

클러스터에 접근 가능한 터미널에서 IngressClass, Ingress와 프로듀서의 준비된 주소를 확인한다.

```bash
kubectl get ingressclass traefik
kubectl -n dangcharge get ingress api-routing
kubectl -n dangcharge get endpointslice -l kubernetes.io/service-name=command-api
```

FIP에 접근 가능한 머신에서 Host를 지정해 origin 경로를 확인한 뒤 외부 도메인을 확인한다.

```bash
curl -i --connect-timeout 5 --max-time 15 \
  -H 'Host: api.dangcharge.cloud' \
  http://10.20.0.150/api/v1/vehicle-models

curl -i --connect-timeout 5 --max-time 15 \
  https://api.dangcharge.cloud/api/v1/vehicle-models
```

위 API가 실제 이미지에 구현되어 있는지와 인증 조건을 함께 확인한다.
`Synced` 또는 응답 코드만으로 전체 API 동작을 판정하지 않는다.
실패하면 Cloudflare 연결, Host 전달, Ingress 규칙, 프로듀서 로그와 실제 API 구현을 구분해 확인한다.
