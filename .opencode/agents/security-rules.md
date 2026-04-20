# {PROJECT_NAME} Security Rules
# Loaded by AG-04 (Developer) and AG-05 (Security Agent)
# Both agents use this identical file.

## 4.1 Input and Injection

### SQL — Parameterised queries only
- Every SQL statement uses $1/$2 placeholders
- No string concatenation or template literals in queries
- FAIL: any query built with string concatenation or interpolated user values

### Prompt injection — Label external content before passing to agent
- Email body, calendar titles, and task content must be wrapped in explicit context tags marking them as untrusted
- FAIL: any external content passed raw into an agent message without an untrusted label

### Input validation — Validate all Telegram input
- Every message handler validates: chat_id matches whitelist, message non-empty, length within 4000 chars
- FAIL: missing whitelist check, no length cap, or processing empty messages

### Cron injection — Validate cron expressions before storing
- cron_expression must be validated with strict regex and parsed by node-cron validate() before DB write
- FAIL: unvalidated cron strings stored in the automations table

## 4.2 Secrets and Credentials

### Env vars — Secrets in .env only
- No secrets in source code, config files, or comments
- All secrets via process.env only
- FAIL: any hardcoded string matching: sk-, token, password, secret, key (case-insensitive)

### Logging — Never log secrets
- No log call that could output env vars, tokens, or credentials
- FAIL: any log statement including process.env values or variables named token/key/secret/password

### Agent exposure — Secrets never reach the agent
- No env var value included in any string passed to the Anthropic API
- FAIL: any Anthropic API call where messages or system contain env var values

### Git — No secrets in git history
- .env and .env.* must be in .gitignore
- FAIL: .env missing from .gitignore, or any commit containing secret-pattern strings

## 4.3 Authentication and Access

### Telegram — Whitelist on every handler
- Every handler (messages, callback queries, inline buttons) checks chat_id against TELEGRAM_ALLOWED_CHAT_ID first
- FAIL: any handler that processes a message without a whitelist check

### Database — No agent-constructed SQL
- The agent never constructs SQL
- All DB access goes through typed tool functions in db/
- FAIL: any code path where agent output is used to construct a SQL statement

### MCP — OAuth tokens stored securely
- OAuth tokens for Google services stored in .env or secrets store — never in PostgreSQL or source code
- FAIL: OAuth tokens written to DB or appearing in source files

### Admin UI — Not externally exposed
- Any admin service bound to 127.0.0.1 only
- FAIL: admin service with ports binding to 0.0.0.0

## 4.4 Data Handling

### PII — No PII in logs
- People names, email addresses, phone numbers, calendar event details must not appear in logs
- FAIL: log statements including people.name, email content, or calendar event titles

### External content — Label all external content as untrusted
- Email bodies, calendar descriptions, and Todoist content always labelled as untrusted when passed to agent
- FAIL: external content passed to agent without explicit untrusted labelling

### Error messages — No stack traces to Telegram
- Error messages sent via Telegram must be plain language only
- FAIL: any catch block that sends error.message or error.stack directly to Telegram

### DB queries — Statement timeout enforced
- Every database connection must have statement_timeout set
- FAIL: pg pool config missing statement_timeout

## 4.5 Dependency Security

### Audit — Zero high or critical vulnerabilities
- pnpm audit must return zero high or critical findings
- FAIL: any high or critical finding in pnpm audit output

### Pinning — All dependencies pinned to exact versions
- package.json must use exact versions — no ^ or ~ prefixes
- FAIL: any dependency with ^ or ~ prefix

### Minimal surface — No unjustified new dependencies
- Each new dependency must have a clear justification in the task manifest
- FAIL: any new package added without manifest justification
