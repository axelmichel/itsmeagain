# Jira (read-only, several sites)

Status: implemented (awaiting review; untested against a real site) · Created: 2026-11-21

## Goal

Ask about tickets in Chat and get the basics fast: status, assignee, description, latest comments.
Several Jira sites at once (e.g. two employers' or clients' instances). Strictly read-only.

## Decision: REST with tokens, not MCP

- The local Chat model (`gemma4:26b`) handles two small, focused tools reliably; the Atlassian MCP
  server exposes many tools (Jira + Confluence, read and write) with large schemas, which local
  models handle poorly and which cost a lot of context.
- Read-only by construction: the client only issues read requests (`GET`, plus the read-only search
  endpoint). With MCP, read-only would only be a filter in the app.
- Native commands (`/jira KEY`) need no model and answer instantly.
- MCP stays the general mechanism for later (phase 2.7 of the assistant plan), when several MCP
  services are wanted.

## Connections

Settings → Jira: a list of connections, each

| Field | Notes |
|---|---|
| Name | "Work", "Client X" — shown in results |
| Base URL | `https://company.atlassian.net` or a Data Center URL |
| Kind | Cloud (API v3, ADF descriptions) or Data Center (API v2, wiki markup) — detected from `/rest/api/*/serverInfo` |
| Auth | Cloud: email + API token (Basic). Data Center: personal access token (Bearer) |
| Token | macOS Keychain, one item per connection; never in UserDefaults, logs or prompts |
| Enabled | per connection |

"Test connection" calls `/myself` and `/project/search` (or `/project` on Data Center) and stores
the connection's **project keys** (refreshed daily). Recommendation shown in the UI: on Cloud use a
**scoped token** with `read:jira-work` + `read:jira-user` so Jira itself enforces read-only.

## Resolving a ticket to its site

- A key (`WTDEV-1857`) is matched by its project prefix against the cached project keys.
- One match → that site. Several sites with the same prefix → query all of them and show each
  result labelled with its connection. No match → try every enabled site (keys may be new), then
  "not found in any of your Jira sites".

## Package: `Jira` target

- `JiraConnection` (id, name, baseURL, kind, email?, projectKeys, enabled), `JiraIssue` (key,
  site, summary, status, statusCategory, assignee, reporter, priority, type, updated, url,
  description text, comments [author, date, text], subtasks/links count).
- `JiraClient` (per connection, `URLSession`, 20 s timeout, no redirects to other hosts):
  `myself()`, `projects()`, `issue(key, comments: 5)`, `search(jql, limit: 20)`.
  Cloud search uses `GET /rest/api/3/search/jql`; Data Center `GET /rest/api/2/search`.
- `ADFText`: Atlassian Document Format → plain text (paragraphs, lists, headings, code, mentions,
  links as "text (url)"); `WikiMarkupText` for Data Center (strip `{code}`, `h1.`, `*bold*` …).
- `JiraDirectory`: all connections, key → site resolution, fan-out search across sites (parallel,
  per-site errors reported, not fatal).
- Text from Jira (descriptions, comments) is third-party content: wrapped as
  `<untrusted source="jira">`, truncated (description 4K, comments 600 chars each).

## Tools (Chat only; private; local models only)

- `jira_issue(key)` — one ticket with the latest comments.
- `jira_search(query, site?, mine?, status?, updated_days?)` — the model passes simple filters; the
  app builds the JQL (no free JQL from the model, so no surprises), up to 20 results across sites.

## Commands

| Command | What it does |
|---|---|
| `/jira <KEY>` | Ticket card: title, status badge, assignee, priority, updated, gist of the description, last 3 comments, link. Native, no model. Several keys allowed. |
| `/myjira [site]` | My open tickets across all sites (or one), grouped by site then status. Native. |
| `/jira <text>` (no key) | Prompt command: search and summarise with `jira_search`. |

Attachment `.jiraIssues([JiraIssue])` renders cards (status colour by category, open in browser).

## Mail integration

- Ticket keys in mail subjects/bodies whose prefix matches a known project become links (opening
  the ticket) in `/inbox`, `/triage` and the Mail watch.
- Optional, off by default: a status hint next to such mails ("WTDEV-1857 · In Review").

## Security and privacy

- Read-only client; token per connection in the Keychain; Test connection never prints the token.
- Jira data is private: tools are `.private` (local models only), the egress lock applies after a
  Jira read, nothing from Jira goes into memory learning (tool output is never read for memory).
- Only the configured hosts are contacted; no redirects to other hosts.

## Tests

- `URLProtocol` stub fixtures: Cloud issue with ADF + comments, Data Center issue with wiki markup,
  search pages, 401 / 403 / 404, rate limit (429 with Retry-After).
- Key resolution with overlapping prefixes; fan-out with one site failing.
- ADF and wiki markup conversion; untrusted wrapping; truncation.
- Policy: Jira tools withheld from non-local providers.
- Live test (opt-in, `JIRA_LIVE=1`): counts and timings only.

## Effort

About one day: client + converters + directory (half), tools/commands/cards/settings (half).

## Open questions

1. Site URLs and whether each is Cloud or Data Center.
2. Scoped (read-only) tokens available on your sites?
3. Which statuses count as "open" for `/myjira` (default: status category ≠ Done)?

## Implemented (2026-11-21)

- `Jira` target: `JiraClient` (GET only; https only; Basic auth on Cloud, Bearer on Data Center;
  no redirects to other hosts; server type detected from `serverInfo`), ADF and wiki-markup to
  text, `JiraDirectory` (key → site by project prefix, all sites when unknown; parallel search;
  per-site failures reported), `JiraQuery` (filters → JQL, no model-written JQL), tools
  `jira_issue` / `jira_search` (private, untrusted-wrapped).
- App: Settings → Assistant → Jira (add site with name, address, email, token; Test detects
  Cloud/Data Center, checks the token and loads project keys; enable/remove), tokens in the
  Keychain (`jira.<id>`); `/jira KEY…` as ticket cards, `/jira words` and `/myjira [site]` as
  lists grouped by site and status.
- Tested with stub servers (Cloud ADF + Basic, Data Center wiki + Bearer, errors, routing,
  JQL escaping). Not yet: ticket keys in mail linked with status.
