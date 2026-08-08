# issues.lak.nz — Down-detector style issue reporter

Single FastAPI app for `issues.lak.nz`: users check is-it-just-me for Prayer Bot, Hawkins Radio, and DocDocGo.

- Landing `/` lists 3 services with live Gatus status + 24h sparkline + spike banner
- Per-service `/s/{svc}`: big Report button, live status, 24h chart, recent reports
- Report `/s/{svc}/report` → `POST /api/report` (form or JSON): stores locally + optionally creates GitHub issue if `GITHUB_TOKEN` set
- Aggregates: `GET /api/stats`, `GET /api/reports/{svc}`

## Run

```
docker compose up -d
# health
curl http://localhost:8787/health
```

Tunnel ingress: `issues.lak.nz` → `0.0.0.0:8787` via `8001-oracle-4armcpu` tunnel (`tf-cloudflare/live/tunnel-config.tf`).
Gatus: `issues.lak.nz` endpoint in `gatus/config/config.yaml` (checks `/health` = 200 + body contains `ok`).

Env: `GITHUB_TOKEN` (optional), `GATUS_URL` (default `http://gatus-gatus-1:8080`), `DATA_FILE`.
