# List Syntax Cases

Unordered list with the default marker:

- First bullet
- Second bullet
- Third bullet

Alternative bullet markers:

* Asterisk bullet
+ Plus bullet
- Hyphen bullet after alternatives

Nested unordered list:

- Project
  - Draft
    - Collect notes
    - Write summary
  - Review
- Release

Ordered list:

1. First item
2. Second item
3. Third item

Ordered list with a non-one start:

7. Starts at seven
8. Continues at eight
9. Keeps counting

Ordered list using a closing parenthesis:

1) Parenthesis item one
2) Parenthesis item two

Mixed ordered markers:

1. Dot marker
2) Parenthesis marker after dot
3. Dot marker again

Task list:

- [ ] Unchecked task
- [x] Checked lowercase task
- [X] Checked uppercase task
- [-] Ambiguous task marker

Nested tasks:

- [ ] Parent task
  - [x] Completed child
  - [ ] Open child

Continuation paragraph:

- Bullet with a continuation paragraph.

  This paragraph belongs to the bullet and should align with the item body.

- Next bullet after the continuation.

Indented code inside a list:

- Item before code

      key: value
      list:
        - this stays code

- Item after code

Four-space indented code outside a list:

    - This should stay code, not become a bullet.
    1. This should stay code, not become ordered.

Malformed or literal list-looking text:

-not a list item because there is no space
1.not ordered because there is no space
- [ ]task missing the space after the checkbox
- [] empty brackets are not a task
