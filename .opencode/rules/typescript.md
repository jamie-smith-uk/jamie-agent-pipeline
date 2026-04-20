# TypeScript Rules (always active)

- Strict mode at all times — tsconfig must have strict: true
- No any types without explicit justification in a comment
- Run tsc --noEmit after every change — fix all errors before marking work done
- Run ESLint after every change — fix all errors before marking work done
- No console.log in production code — use a structured logger
- All async functions must have proper error handling
- No unused imports or variables
