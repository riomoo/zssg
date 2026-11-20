---
title: t
---
# Title with `code` and *em*

Paragraph with trailing spaces  
hard break and backslash\
break. Escapes: \* \_ \# \[x\] and &copy; &amp; & < > "q" 'a' don't -- --- ... 5 * 3 * 2 __init__ a_b_c *a **b** c* **a *b* c** ***x*** _*y*_ **bold**text mid*em*phasis.

Auto <https://a.b/c?d=1&e=2> and <me@x.org> and www.example.com/path, https://x.y/z. (https://p.q/r) [ref][one] [two] [Two][] ![img](a.png "T") [empty]() [link *em* `c`](</my url> 'ti"tle').

[one]: https://one.example "One"
[two]: <https://two.example>

Setext One
==========

Setext Two
----------

### Dup
### Dup
#### Ünïcödé Heading & more!
##### Closed #####

* a
* b

  para in b

  ```
  code in b
  ```
* c
    * deep
        1. one
        2. two
- other list
+ third list

1. one
1. two
   - nested
3. three

10. ten
11. eleven

- [ ] task
- [x] done

> quote
> > nested quote
> - list in quote
>
> ```js
> let x = 1; // c
> ```

    indented code
      more

~~~python
def f(x):
    return "s" # c
~~~

```
no lang <b>
```

| Left | Center | Right | None |
|:-----|:------:|------:|------|
| a | b | c | d |
| `x` | **y** | [l](u) | \| pipe |
| short |

Term 1
: Def 1
: Def 2

Term 2
: Def with *em*

<div class="raw">
<p>raw *not md*</p>
</div>

<details>
<summary>S</summary>

inner **md**

</details>

Inline <span class="x">html</span> and <br> and <!-- comment --> here.

Foot[^a] and again[^a] and other[^b].

[^a]: Note A with **bold**.
[^b]: Note B
    continued.

***

Line one
line two~~struck~~ and H~2~O.

Final paragraph with image alone:

![alone](b.png)
