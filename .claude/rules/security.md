# Security Guidelines

## Mandatory Security Checks

Before any commit, apply the checks that are relevant to the code touched:
- [ ] No hardcoded secrets (API keys, passwords, tokens)
- [ ] Inputs at system boundaries validated
- [ ] File paths and user-selected files handled deliberately
- [ ] SQLite queries parameterized when persistence code exists
- [ ] FFI boundaries validate nullability, encoding, ownership, and lifetimes
- [ ] Security-scoped file access is explicit where sandboxed file access is involved
- [ ] Error messages do not leak sensitive data

## Secret Management

- NEVER hardcode secrets in source code
- ALWAYS use environment variables or a secret manager
- Validate that required secrets are present at startup
- Rotate any secrets that may have been exposed
- Do not add secret storage unless the product feature genuinely needs it

## Security Response Protocol

If security issue found:
1. STOP immediately
2. Use a security-focused reviewer or subagent when available
3. Fix CRITICAL issues before continuing
4. Rotate any exposed secrets
5. Review nearby code and related entry points for similar issues
