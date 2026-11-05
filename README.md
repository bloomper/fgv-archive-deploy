# Spexarkivet Deploy

Docker Compose setup for running Spexarkivet (API, worker, web and MySQL) on a single host, next to
[spexregister-deploy][1] and [fgv-infra-deploy][2], which runs Keycloak, the mail relay on staging and the shared
network `fgv-<DEPLOY_ENV>`.

Cloudflare is used on staging only. Production uses its own reverse proxy for `WEB_HOST` and `API_HOST` (see
*Production*). There is no media hostname: files are served by the API and streamed by the web.

```
Staging:
Browser ──https──▶ Cloudflare ──tunnel──▶ cloudflared ─┬─▶ archive-web:3000             (WEB_HOST)
                                                       └─▶ archive-api:8080             (API_HOST, for /docs)

archive-web ──▶ archive-api ──▶ archive-mysql
                archive-worker ──▶ archive-mysql                 (reads text, renders previews)
                archive-api ──▶ keycloak-server, spexregister-api, mail relay   (fgv network)
```

- The web goes through the Cloudflare Tunnel like Spexregister. Documents are not media in the sense of Cloudflare's
  CDN terms, so no DNS-only hostname is needed. Uploads are tus chunks of at most 50 MB through the web, below the
  request limit of Cloudflare's free plan.
- The web streams files, previews and zips from the API with the user's token, or a share link's token, passing byte
  ranges on so that pdf.js loads large PDFs page by page. Share link pages (`/share/<token>`) need no login.
- `archive-worker` is the API's image with `API_WORKER_ENABLED=true`: it reads new files' page counts and text for
  search, and renders their first-page previews, one at a time.

## Files

| File                          | Purpose                                                                    |
|-------------------------------|----------------------------------------------------------------------------|
| `compose.yaml`                | `archive-mysql`, `archive-api`, `archive-worker`, `archive-web`            |
| `compose.tunnel.yaml`         | `cloudflared` connector for `WEB_HOST` and `API_HOST`, staging only        |
| `staging.env.example`, `production.env.example` | Templates for `.env`                                     |
| `bin/init-secrets.sh`         | Generates secrets into `secrets/` and copies the client secrets from `fgv-infra-deploy` |
| `bin/backup-db.sh`            | Dumps the database into `backups/`, pruning dumps older than 14 days       |
| `bin/backup-files.sh`         | Backs up `data/archive/files/` with restic                                 |

| `.env` variable | Image                         | Source repo          |
|-----------------|-------------------------------|----------------------|
| `API_IMAGE`     | `bloomper/fgv-archive-server` | `fgv-archive-server` (API and worker) |
| `WEB_IMAGE`     | `bloomper/fgv-archive-web`    | `fgv-archive-web`    |

## 1. Host

- `fgv-infra-deploy` running with a realm that has the `fgv-archive` and `fgv-archive-service` clients. Its `.env`
  names this deployment's `WEB_HOST` as `ARCHIVE_WEB_HOST`.
- `spexregister-deploy` running a `spexregister-server` release that accepts `fgv-archive-service` with the `MEDIA` role.
- Disk for the files: the whole archive is expected to stay well below 100 GB.

## 2. Cloudflare (staging only)

Only staging uses Cloudflare. On production, skip this section and point `WEB_HOST` and `API_HOST` at production's
reverse proxy (see *Production*).

1. Create a tunnel (Networking → Tunnels → *Create a tunnel* → Cloudflared), e.g. `fgv-archive-staging`, and copy
   its token.
2. On the tunnel's **Routes** tab, add a published application for each row below:

   | Hostname     | Service URL                |
   |--------------|----------------------------|
   | `WEB_HOST`   | `http://archive-web:3000`  |
   | `API_HOST`   | `http://archive-api:8080`  |

3. Restrict `WEB_HOST` to testers with Cloudflare Access, as `spexregister-deploy`'s README describes, but leave
   `WEB_HOST/share/*` and `WEB_HOST/api/share/*` open, since share links work without logging in. Leave `API_HOST`
   unprotected, as Spexregister's: the API requires a Keycloak token for everything but share links.

## 3. Checkout and configuration

```shell
git clone https://github.com/bloomper/fgv-archive-deploy.git
cd fgv-archive-deploy

cp staging.env.example .env          # set the hostnames
bin/init-secrets.sh                  # copies the client secrets from ../fgv-infra-deploy
nano secrets/cloudflared.env         # staging only: TUNNEL_TOKEN=<token from step 2>
nano secrets/SMTP_PASSWORD           # production: the mail relay's password
mkdir -p data/api/log_data data/worker/log_data data/archive
sudo chown -R 1000:1000 data
docker compose up -d
```

| Variable                          | Purpose                                                                      |
|-----------------------------------|------------------------------------------------------------------------------|
| `WEB_HOST`                        | Spexarkivet's address; also the links in the emails about access requests    |
| `API_HOST`                        | Public address of the API, for `/docs`                                       |
| `KEYCLOAK_HOST`, `KEYCLOAK_REALM` | Keycloak's public address and realm                                          |
| `WORKER_CPUS`                     | CPUs the worker may use                                                      |
| `SMTP_*`, `MAIL_FROM`             | The mail relay for requests for access to restricted files; Mailpit on staging |
| `SPEXREGISTER_GRAPHQL_URL`        | Spexregister's GraphQL endpoint on the shared network                        |
| `SPEXREGISTER_WEB_URL`, `FGV_REVIVAL_WEB_URL`, `SPEXIFY_WEB_URL`, `SPEXFLIX_WEB_URL`, `SPEXGRAM_WEB_URL` | The other applications, for the application switcher |
| `API_IMPORT_SAMPLE_DATA`          | `true` on staging only: replaces all data at every start                     |
| `API_SAMPLE_DATA_SIZE`            | `small` or `large`                                                           |
| `SUPPORT_EMAIL`, `FEEDBACK_EMAIL` | Shown on the Support and About pages                                         |
| `UMAMI_WEBSITE_ID`                | Umami website for `WEB_HOST`; without it the web sends no statistics. Share link pages are never tracked |

For visitor statistics, run `bin/configure-umami.sh` in `fgv-infra-deploy` (see *Umami* in its README). It adds a
website `ARCHIVE_NAME` for `ARCHIVE_WEB_HOST` and prints its ID; put that ID in `UMAMI_WEBSITE_ID`.

The editors are told about access requests by email; the settings in the web can name the recipients instead. Reading
the editors from Keycloak needs `realm-management`'s `view-users` and `view-clients` on `fgv-archive-service`.

## Storage

Everything lies under `data/archive/`, mounted into the API and the worker:

| Folder      | Content                                                | Back up |
|-------------|--------------------------------------------------------|---------|
| `files/`    | The uploaded files, by version and file id             | Yes, `bin/backup-files.sh` |
| `previews/` | First-page previews; the `FILE_BACKFILL` job remakes missing ones | No |
| `uploads/`  | Unfinished uploads, deleted after 24 hours             | No      |

## First start

The API creates its tables, copies the spex from Spexregister, and on staging (`API_IMPORT_SAMPLE_DATA=true`) replaces
all data with sample data built on Spexregister's sample spex, which the worker then reads; see *Sample data* and *Test
credentials* in `fgv-archive-server`'s getting started guide for the users and the sample share links. Spexregister
deletes all Keycloak users on every start of its sample import, so restart Spexarkivet after it:
`docker compose restart archive-api`.

## Production

- `.env` from `production.env.example`: `DEPLOY_ENV=production` (the API then refuses sample data),
  `API_IMPORT_SAMPLE_DATA=false`, and images pinned to release versions.
- No Cloudflare: `COMPOSE_FILE` leaves out `compose.tunnel.yaml` and needs no `secrets/cloudflared.env`. Production's
  own reverse proxy terminates TLS and forwards `WEB_HOST` to `archive-web:3000` (tus chunks of up to 50 MB) and
  `API_HOST` to `archive-api:8080`.
- `bin/backup-db.sh` and `bin/backup-files.sh` in cron, with `backups/` copied off the host.
- Existing material is moved in once with `fgv-archive-migration`.

## Troubleshooting

| Symptom                                            | Cause                                                                      |
|----------------------------------------------------|----------------------------------------------------------------------------|
| Files have no preview and search finds no text     | `archive-worker` is down; see its log                                      |
| Editors get no email about access requests         | The mail relay refuses (see the API's log), or `fgv-archive-service` lacks `view-clients` and no recipients are set |
| Share links ask for a login (staging)              | Cloudflare Access covers `/share/*` and `/api/share/*`                     |
| Login fails with "Invalid parameter: redirect_uri" | `ARCHIVE_WEB_HOST` in `fgv-infra-deploy` doesn't match `WEB_HOST`         |

[1]: https://github.com/bloomper/spexregister-deploy
[2]: https://github.com/bloomper/fgv-infra-deploy
