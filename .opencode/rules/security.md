# Security Rules (always active)

These rules apply to every agent in every session.

- Never hardcode secrets, tokens, or credentials
- Never log environment variable values
- Always use parameterised queries — no SQL string concatenation
- Never include env var values in strings passed to the Anthropic API
- Always authenticate the caller on every external handler before processing input
- Never send stack traces or internal error details to external callers
- Pin all npm dependencies to exact versions — no ^ or ~ prefixes
