# Showcase Document

This fixture exercises every construct the viewer should render. It opens
with a plain paragraph that is long enough to wrap at a typical terminal
width, so that word wrapping, *emphasis*, **strong emphasis**, ***both***,
`inline code`, ~~strikethrough~~ and a [link to Frogmouth](https://github.com/Textualize/frogmouth)
all appear in running text. Autolinks like <https://www.gnu.org/software/emacs/>
and bare URLs such as https://example.com are also here.

## Second-level heading

A paragraph after an H2. Entities: &amp; &lt; &gt; &copy; &mdash; and escapes: \*not emphasis\*,
\# not a heading. Hard line break follows (two trailing spaces)  
and this is on the next line. A backslash break\
also works.

### Third-level heading

#### Fourth-level heading

##### Fifth-level heading

###### Sixth-level heading

Setext Heading One
==================

Setext Heading Two
------------------

---

## Lists

- First bullet item
- Second bullet item with a long line that should wrap neatly under the text
  of the item rather than under the bullet marker, which is the typical thing.
  - Nested bullet, level two
  - Another nested bullet
    - Level three bullet
      - Level four bullet
        - Level five bullet
- Third bullet with `code` and **bold**

1. Ordered item one
2. Ordered item two
   1. Nested ordered item
   2. Another nested ordered item
3. Ordered item three

10. Starting at ten
11. Eleven
12. Twelve

- [ ] An unchecked task
- [x] A checked task
- [ ] Another task with a [link](README.md)

* Loose list item one

* Loose list item two, separated by blank lines, with a second paragraph:

  Second paragraph inside the loose item.

  ```sh
  echo "code inside a list item"
  ```

## Block quotes

> A simple block quote with enough text to wrap around onto a second line so that
> the left border is drawn on every line of the quote.

> Nested quotes:
>
> > Inner quote, second level.
> >
> > > Third level.
>
> Back to the first level with a list:
>
> - quoted bullet one
> - quoted bullet two

## Code

Indented code block:

    def indented():
        return "four spaces"

Fenced with a language:

```python
import sys
from dataclasses import dataclass


@dataclass
class Point:
    """A point in the plane."""
    x: float
    y: float

    def norm(self) -> float:
        # Euclidean norm
        return (self.x ** 2 + self.y ** 2) ** 0.5


if __name__ == "__main__":
    print(Point(3, 4).norm(), file=sys.stderr)
```

```elisp
(defun greet (name)
  "Say hello to NAME."
  (interactive "sName: ")
  (message "Hello, %s!" name))
```

~~~
Tilde fence with no language and a very long line that should not be wrapped: 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789
~~~

## Tables

| Column A | Column B | Column C |
|----------|:--------:|---------:|
| left     | center   | right    |
| `code`   | **bold** | *italic* |
| a longer cell value | x | 12345.67 |

| Feature | Supported |
|---|---|
| Images | yes |
| Tables | yes |
| Footnotes | partially |

Table with inline link and wrapped content:

| Name | Description |
|------|-------------|
| [Frogmouth](https://github.com/Textualize/frogmouth) | A Markdown browser for the terminal, built with Textual. It renders tables, code and more. |
| Emacs | An extensible, customizable, free/libre text editor, and more. |

## Images

![Sample image](images/sample.png)

Inline image in a paragraph: ![tiny](images/sample.svg) followed by text.

![Missing image](images/does-not-exist.png)

[![Linked image](images/sample.png)](https://example.com)

## HTML and misc

<div align="center">
  <b>Raw HTML block</b>
</div>

Inline <kbd>Ctrl</kbd>+<kbd>C</kbd> html and a <br> break.

Footnote reference[^1] and another[^note].

[^1]: The first footnote.
[^note]: A named footnote with *markup*.

Reference-style [link][ref] and ![ref image][img].

[ref]: https://www.gnu.org/software/emacs/ "GNU Emacs"
[img]: images/sample.png

Term with a very long unbreakable token: Pneumonoultramicroscopicsilicovolcanoconiosis_Pneumonoultramicroscopicsilicovolcanoconiosis_Pneumonoultramicroscopicsilicovolcanoconiosis

***

Final paragraph. The end.
