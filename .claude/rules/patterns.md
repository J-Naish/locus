# Common Patterns

## External References

When implementing new functionality:
1. Study Apple, Rust, SQLite, and existing project examples before inventing new structure
2. Use parallel agents to evaluate options when the decision is broad or risky:
   - Security assessment
   - Native platform fit
   - Relevance scoring
   - Implementation planning
3. Prefer adapting the current project's architecture over importing external structure
4. Do not clone or vendor external project structure into the repository unless explicitly approved

## Design Patterns

### Local Persistence Boundary

Use only when SQLite or durable local persistence appears. Encapsulate persistence behind a small, testable boundary:
- Keep SQL and schema details out of UI views
- Keep platform UI code from calling raw persistence APIs directly
- Use focused operations that match the product workflow
- Make persistence behavior testable with temporary databases or fixtures
- Avoid adding a repository layer for simple local file reads or one-off operations

### FFI Boundary

Keep Rust and native app integration coarse and explicit:
- Rust owns Rust-allocated memory and exposes a matching free function
- C ABI structs stay versioned and layout-tested
- Platform bridges copy borrowed FFI data into native values before freeing Rust snapshots
- Status codes and error messages remain stable and tested
