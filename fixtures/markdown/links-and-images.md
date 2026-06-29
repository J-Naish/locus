# Links And Images Syntax Cases

Inline link: [requirements](../../docs/requirements.md).

Inline link with title: [product brief](../../docs/product/brief.md "Product brief").

Reference link: [brief][product-brief].

Collapsed reference link: [requirements][].

Shortcut reference link: [Roadmap].

Autolink: <https://example.com/reports/q2>.

Email autolink: <review@example.com>.

Unsafe link should not become an active link:
[bad](javascript:alert(1)).

Escaped link syntax should stay literal:
\[not a link\](https://example.com).

Image with alt text:

![Fixture image](../media/valid/locus-fixture.svg)

Bitmap image:

![Sample bitmap](../media/valid/markdown-images/earthrise-nasa.jpg)

Image without alt text:

![](../media/valid/markdown-images/product-still.png)

Missing image:

![Missing image](no-such-image.png)

Image inside a link:

[![Fixture image](../media/valid/locus-fixture.svg)](../../docs/requirements.md)

Reference-style image:

![Referenced image][fixture-svg]

[product-brief]: ../../docs/product/brief.md
[requirements]: ../../docs/requirements.md
[Roadmap]: ../../docs/product/mvp-roadmap.md
[fixture-svg]: ../media/valid/locus-fixture.svg
