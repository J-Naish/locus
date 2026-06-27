# Blockquote Syntax Cases

> A single-line blockquote.

> A multi-line blockquote starts here.
> It continues on the next source line.
> It should share one visual quote treatment.

> Lazy continuation starts in a quote.
This line is a lazy continuation in CommonMark-style parsers.

> Nested quote level one.
>> Nested quote level two.
>>> Nested quote level three.

> ## Heading inside a quote
>
> Paragraph after the quoted heading.

> - Quoted bullet
> - Quoted bullet with **bold**
>   - Nested quoted bullet

> 1. Quoted ordered item
> 2. Another quoted ordered item

> - [ ] Quoted task
> - [x] Completed quoted task

> | Field | Value |
> | --- | --- |
> | status | draft |
> | owner | docs |

> ```yaml
> status: draft
> reviewers:
>   - nishi
> ```

> A quote before a rule.
>
> ---
>
> A quote after a rule.

Plain paragraph after quotes should not inherit the quote bar.
