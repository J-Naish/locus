# Code Fence Syntax Cases

Backtick fence with JSON:

```json
{
  "fixture": true,
  "count": 3
}
```

Swift fence:

```swift
let title = "Locus"
print(title)
```

Fence without a language:

```
# This should stay code, not become a heading.
- This should stay code, not become a list.
```

Tilde fence:

~~~yaml
name: pdf
allowed-tools:
  - Read
  - Write
~~~

Fence with extra info string text:

```python linenums="1"
def greet(name):
    return f"Hello, {name}"
```

Backticks inside a longer fence:

````markdown
```json
{ "nested": true }
```
````

Indented code block:

    status: draft
    reviewers:
      - nishi

Indented code inside a list:

- Before code

      # Still code
      - Not a nested list

- After code

Fence markers inside a quote:

> ```text
> quoted code
> ```

Intentionally unclosed fence at EOF:

```text
This fence is not closed.
The renderer should keep the rest of the file in code style without crashing.
