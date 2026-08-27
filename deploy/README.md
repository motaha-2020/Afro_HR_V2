# Deploying the Afro_HR_V2 database container

Target server: `100.122.6.64` (Portainer 2.39.3 on :9000, Postgres already
occupying host port 5432 — this stack uses **55432** instead).

## Option A — from the server shell

```bash
git clone <repo-url> afro_hr_v2 && cd afro_hr_v2/deploy
cp .env.example .env && nano .env      # set POSTGRES_PASSWORD
docker compose -p afrohr up -d
docker logs -f afrohr-migrate          # should end with "migrations + seed applied"
```

## Option B — from Portainer

Stacks → Add stack → Repository → point at this repo, compose path
`deploy/docker-compose.yml`, and add `POSTGRES_PASSWORD` as an environment
variable. Deploy.

## Verifying

```bash
docker exec -it afrohr-db psql -U afro -d afro_hr -c "\dn"
docker exec -i afrohr-db psql -U afro -d afro_hr -v ON_ERROR_STOP=1 < ../db/tests/T001__integrity_rules.sql
docker exec -i afrohr-db psql -U afro -d afro_hr -v ON_ERROR_STOP=1 < ../db/tests/T002__temporal_and_isolation.sql
```

The tests print `PASS` / `FAIL` lines per business rule (ERD §42–§53).

## Connecting from outside

```
postgresql://afro:<password>@100.122.6.64:55432/afro_hr
```

## Resetting

```bash
docker compose -p afrohr down -v && docker compose -p afrohr up -d
```

`-v` drops the volume — the migrations are not idempotent yet, so a re-run
without a reset will fail on duplicate objects. A migration-history table comes
with the ASP.NET Core layer.
