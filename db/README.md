# Afro_HR_V2 — Database Core v1.0

The first executable slice of the blueprint: **Domains 01–05 + 08 + 11**, plus the
shared Config / Audit / Integration layers. Everything here traces back to a
specific section of `analysis/System Master Blueprint v1.0/`.

## Stack
PostgreSQL 17 (per `02.txt` — chosen partly for Row Level Security).
Backend will be ASP.NET Core 10 modular monolith; frontend React + Vite (`03.txt`).

## What is in here

| File | Domain | Key source |
|---|---|---|
| `V001` | Extensions, schemas, session context, audit columns, RLS helper | ERD §2, §46, §47 |
| `V002` | Tenant, Company, number sequences | ERD §3–§5, §54–§55 |
| `V003` | Reference data + state machines | ERD §8, §20, §24, §50–§53 |
| `V004` | Org units, jobs, grades, locations, cost centres | ERD §6–§10 |
| `V005` | Positions + reporting relationships | ERD §11–§14 |
| `V006` | Employee (person) + supporting tables | ERD §15–§17 |
| `V007` | Employment (the work relationship) | ERD §18–§21 |
| `V008` | Assignments, projects, sites | ERD §22–§27 |
| `V009` | Employment contracts | ERD §28–§32 |
| `V010` | Compensation packages + components | ERD §33–§38 |
| `V011` | Users, roles, permissions, scopes | Domain Map §6 |
| `V012` | Audit change log + domain event outbox | ERD §46; Master Map events |
| `V013` | Point-in-time functions and org chart | ERD §44–§45 |

## The decisions that shaped it

- **Job ≠ Position.** One `Project Manager` job, many seats (PM–Huawei, PM–Nokia).
- **Employee ≠ Employment.** A person can have several employments over time,
  across several legal companies in the same tenant.
- **Nothing is overwritten.** A raise closes one compensation row and opens the
  next. `compensation.package_as_of()` can still answer what June 2026 looked like.
- **Rules live in the database, not only in the service layer.** Overlapping
  contracts, two primary assignments, >100% project allocation, and illegal
  status transitions are all rejected by constraints and triggers.
- **`current_filled` is never stored** — it is derived in `org.v_position_headcount`.
- **Tenant isolation is enforced twice**: composite foreign keys carrying
  `tenant_id` make a cross-tenant row structurally impossible, and RLS blocks
  reads even if the application layer is wrong.

## Running it

```bash
cd db
docker compose up -d
./apply.sh reset     # drop, migrate, seed
./apply.sh test      # assert the business rules actually fire
```

`apply.sh` reads `DB_URL` (default `postgresql://afro:afro_dev_only@localhost:55432/afro_hr`).

## Not yet built

Modules 06–07, 09–10, 12–20 (recruitment, attendance, leave, payroll runs,
performance, learning, cases, offboarding, analytics) and the Shared Capabilities
(Benefits, HSE Readiness, Travel & Expense). Those sit on top of this core and
should follow the same cluster order as `System Master Blueprint v1.0`.
