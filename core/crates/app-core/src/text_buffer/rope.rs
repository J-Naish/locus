//! Persistent rope: a balanced B+-tree of immutable text leaves with cached
//! aggregates, the storage substrate for the editable [`TextBuffer`](super::TextBuffer).
//!
//! Every node is reference-counted (`Arc`) and never mutated in place. An edit
//! rebuilds only the `O(log n)` nodes on the path it touches and shares every
//! untouched subtree with the previous version. That makes a *snapshot* — a
//! clone of the root — `O(1)` and structurally shared, which is the whole reason
//! the editable buffer uses a rope rather than the in-place arena it replaced.
//!
//! Leaves come in two flavours, both immutable:
//! - [`Chunk::Shared`] is a view (offset + length) into the original document's
//!   bytes, held behind an `Arc<dyn ContentBytes>`. The platform has already
//!   loaded those bytes into memory; building the tree over them copies **no**
//!   further content — it only computes each leaf's summary and bumps a refcount.
//! - [`Chunk::Owned`] holds inserted text in its own immutable `Arc<str>`.
//!
//! All data lives in leaves at a uniform depth; internal nodes only route and
//! cache the summary of their subtree. Coordinate conversions and viewport reads
//! live in [`super::coords`] and treat the rope as an ordered byte sequence with
//! a summary; this module knows only the shape.

use std::ops::{Add, AddAssign, Sub};
use std::sync::Arc;

use super::ContentBytes;

/// Target leaf size at build and insert. A few KiB keeps every within-leaf scan
/// bounded (the property the old 64 KiB pieces gave) while keeping a
/// copy-on-write edit's per-leaf copy small. Tunable against `perf-smoke`.
pub(super) const LEAF_TARGET_BYTES: usize = 4 * 1024;

/// Hard cap; a leaf is never built larger than this, so the worst-case `Owned`
/// split copy and the worst-case within-leaf scan stay bounded.
pub(super) const LEAF_MAX_BYTES: usize = 8 * 1024;

/// B-tree fan-out. `B_MIN = B_MAX / 2` keeps a split node at least half full so
/// the tree height stays `O(log n)`.
const B_MAX: usize = 12;
const B_MIN: usize = B_MAX / 2;

/// Cached aggregate counts over a span of UTF-8 text. Forms a monoid under `+`
/// (field-wise, associative, with the zero value as identity), so an internal
/// node caches the sum of its children and an edit recomputes only one path.
#[derive(Clone, Copy, Default, PartialEq, Eq, Debug)]
pub(super) struct TextSummary {
    pub bytes: usize,
    pub chars: usize,
    pub utf16: usize,
    /// Count of `'\n'` only — lone `'\r'` is content, matching the buffer's
    /// line model.
    pub line_breaks: usize,
}

impl TextSummary {
    /// Summary of a UTF-8 string (one bounded scan).
    pub(super) fn of(text: &str) -> Self {
        let mut summary = TextSummary {
            bytes: text.len(),
            ..TextSummary::default()
        };
        for character in text.chars() {
            summary.chars += 1;
            summary.utf16 += character.len_utf16();
            if character == '\n' {
                summary.line_breaks += 1;
            }
        }
        summary
    }
}

impl Add for TextSummary {
    type Output = TextSummary;

    fn add(self, other: TextSummary) -> TextSummary {
        TextSummary {
            bytes: self.bytes + other.bytes,
            chars: self.chars + other.chars,
            utf16: self.utf16 + other.utf16,
            line_breaks: self.line_breaks + other.line_breaks,
        }
    }
}

impl AddAssign for TextSummary {
    fn add_assign(&mut self, other: TextSummary) {
        *self = *self + other;
    }
}

impl Sub for TextSummary {
    type Output = TextSummary;

    fn sub(self, other: TextSummary) -> TextSummary {
        TextSummary {
            bytes: self.bytes - other.bytes,
            chars: self.chars - other.chars,
            utf16: self.utf16 - other.utf16,
            line_breaks: self.line_breaks - other.line_breaks,
        }
    }
}

/// A leaf's bytes: either a view into the shared original, or owned inserted
/// text. Both are immutable, so any leaf is freely shareable across snapshots.
#[derive(Clone)]
enum Chunk {
    Shared {
        backing: Arc<dyn ContentBytes>,
        start: usize,
        len: usize,
    },
    Owned(Arc<str>),
}

impl Chunk {
    fn as_bytes(&self) -> &[u8] {
        match self {
            Chunk::Shared {
                backing,
                start,
                len,
            } => &backing.as_bytes()[*start..*start + *len],
            Chunk::Owned(text) => text.as_bytes(),
        }
    }

    fn as_str(&self) -> &str {
        match self {
            Chunk::Owned(text) => text,
            // The original is validated UTF-8 and every boundary lands on a char
            // boundary, so the slice is always valid UTF-8.
            Chunk::Shared { .. } => std::str::from_utf8(self.as_bytes())
                .expect("rope leaf is validated UTF-8 on char boundaries"),
        }
    }

    fn len(&self) -> usize {
        match self {
            Chunk::Shared { len, .. } => *len,
            Chunk::Owned(text) => text.len(),
        }
    }

    /// A sub-view `[from, to)` of this chunk. `Shared` slices are pure offset
    /// math (no copy); `Owned` copies the (bounded) half. Both endpoints must lie
    /// on char boundaries.
    fn slice(&self, from: usize, to: usize) -> Chunk {
        match self {
            Chunk::Shared { backing, start, .. } => Chunk::Shared {
                backing: backing.clone(),
                start: start + from,
                len: to - from,
            },
            Chunk::Owned(text) => Chunk::Owned(Arc::from(&text[from..to])),
        }
    }
}

pub(super) struct Leaf {
    chunk: Chunk,
    summary: TextSummary,
}

pub(super) struct Internal {
    summary: TextSummary,
    children: Vec<Node>,
    height: u8,
}

/// A persistent rope node. Cloning is `O(1)` (an `Arc` bump) and shares the
/// whole subtree — this clone is the snapshot.
#[derive(Clone)]
pub(super) enum Node {
    Leaf(Arc<Leaf>),
    Internal(Arc<Internal>),
}

impl Node {
    // MARK: - Accessors (the surface `coords` and the buffer read through)

    pub(super) fn summary(&self) -> TextSummary {
        match self {
            Node::Leaf(leaf) => leaf.summary,
            Node::Internal(internal) => internal.summary,
        }
    }

    pub(super) fn height(&self) -> u8 {
        match self {
            Node::Leaf(_) => 0,
            Node::Internal(internal) => internal.height,
        }
    }

    pub(super) fn is_leaf(&self) -> bool {
        matches!(self, Node::Leaf(_))
    }

    /// Child nodes, or an empty slice for a leaf.
    pub(super) fn children(&self) -> &[Node] {
        match self {
            Node::Leaf(_) => &[],
            Node::Internal(internal) => &internal.children,
        }
    }

    /// This leaf's bytes, or an empty slice for an internal node.
    pub(super) fn leaf_bytes(&self) -> &[u8] {
        match self {
            Node::Leaf(leaf) => leaf.chunk.as_bytes(),
            Node::Internal(_) => &[],
        }
    }

    fn leaf_ref(&self) -> &Leaf {
        match self {
            Node::Leaf(leaf) => leaf,
            Node::Internal(_) => panic!("leaf_ref on an internal node"),
        }
    }

    /// Total bytes — convenience for `summary().bytes`.
    pub(super) fn byte_len(&self) -> usize {
        self.summary().bytes
    }

    fn is_empty(&self) -> bool {
        self.summary().bytes == 0
    }

    // MARK: - Construction

    /// The empty rope: a single zero-length leaf (the root is never absent).
    pub(super) fn empty() -> Node {
        Node::leaf(Chunk::Owned(Arc::from("")), TextSummary::default())
    }

    fn leaf(chunk: Chunk, summary: TextSummary) -> Node {
        Node::Leaf(Arc::new(Leaf { chunk, summary }))
    }

    /// Builds a node from `1..=B_MAX` children of equal height. A single child is
    /// returned unwrapped so a degenerate one-child internal never forms.
    fn from_children(mut children: Vec<Node>) -> Node {
        debug_assert!(!children.is_empty() && children.len() <= B_MAX);
        if children.len() == 1 {
            return children.pop().expect("len checked");
        }
        let height = children[0].height() + 1;
        debug_assert!(
            children.iter().all(|child| child.height() + 1 == height),
            "internal children must share a height"
        );
        let mut summary = TextSummary::default();
        for child in &children {
            summary += child.summary();
        }
        Node::Internal(Arc::new(Internal {
            summary,
            children,
            height,
        }))
    }

    /// Builds a balanced rope over the original document `backing`, splitting it
    /// into `Shared` leaves of `cap` bytes (char-aligned). Copies no content.
    pub(super) fn from_backing(backing: Arc<dyn ContentBytes>, cap: usize) -> Node {
        let bytes = backing.as_bytes();
        let len = bytes.len();
        if len == 0 {
            return Node::empty();
        }
        let cap = cap.max(1);
        let mut leaves = Vec::new();
        let mut start = 0;
        while start < len {
            let end = next_chunk_end(bytes, start, cap);
            let text = std::str::from_utf8(&bytes[start..end])
                .expect("backing is validated UTF-8 split on char boundaries");
            let summary = TextSummary::of(text);
            leaves.push(Node::leaf(
                Chunk::Shared {
                    backing: backing.clone(),
                    start,
                    len: end - start,
                },
                summary,
            ));
            start = end;
        }
        build_balanced(leaves)
    }

    /// Builds a balanced rope of `Owned` leaves over inserted `text`.
    pub(super) fn from_str(text: &str) -> Node {
        Self::from_str_capped(text, LEAF_TARGET_BYTES)
    }

    fn from_str_capped(text: &str, cap: usize) -> Node {
        if text.is_empty() {
            return Node::empty();
        }
        let cap = cap.max(1);
        let bytes = text.as_bytes();
        let mut leaves = Vec::new();
        let mut start = 0;
        while start < bytes.len() {
            let end = next_chunk_end(bytes, start, cap);
            let slice = &text[start..end];
            leaves.push(Node::leaf(
                Chunk::Owned(Arc::from(slice)),
                TextSummary::of(slice),
            ));
            start = end;
        }
        build_balanced(leaves)
    }

    // MARK: - Edit primitives

    /// Splits into `(< at_byte, >= at_byte)`. `at_byte` must lie on a char
    /// boundary (every edit offset is char-validated upstream).
    pub(super) fn split(&self, at_byte: usize) -> (Node, Node) {
        let total = self.summary().bytes;
        if at_byte == 0 {
            return (Node::empty(), self.clone());
        }
        if at_byte >= total {
            return (self.clone(), Node::empty());
        }
        match self {
            Node::Leaf(leaf) => {
                let text = leaf.chunk.as_str();
                debug_assert!(text.is_char_boundary(at_byte));
                let (left_summary, right_summary) = split_summary(leaf.summary, text, at_byte);
                (
                    Node::leaf(leaf.chunk.slice(0, at_byte), left_summary),
                    Node::leaf(leaf.chunk.slice(at_byte, leaf.chunk.len()), right_summary),
                )
            }
            Node::Internal(internal) => {
                let mut offset = 0;
                for (index, child) in internal.children.iter().enumerate() {
                    let child_bytes = child.summary().bytes;
                    if at_byte < offset + child_bytes {
                        let (child_left, child_right) = child.split(at_byte - offset);
                        let left = Node::concat(
                            from_children_or_empty(&internal.children[..index]),
                            child_left,
                        );
                        let right = Node::concat(
                            child_right,
                            from_children_or_empty(&internal.children[index + 1..]),
                        );
                        return (left, right);
                    }
                    offset += child_bytes;
                }
                unreachable!("at_byte < total guarantees a child contains it")
            }
        }
    }

    /// Concatenates two ropes (`left` precedes `right`), keeping the result
    /// balanced. The rope analogue of the treap's `merge`, driven by height.
    pub(super) fn concat(left: Node, right: Node) -> Node {
        if left.is_empty() {
            return right;
        }
        if right.is_empty() {
            return left;
        }
        let (height_left, height_right) = (left.height(), right.height());
        match height_left.cmp(&height_right) {
            std::cmp::Ordering::Equal => {
                if left.is_leaf() && right.is_leaf() {
                    merge_leaves(left, right)
                } else {
                    merge_nodes(left.children(), right.children())
                }
            }
            std::cmp::Ordering::Less => {
                let children = right.children();
                let merged = Node::concat(left, children[0].clone());
                if merged.height() == height_right - 1 {
                    merge_nodes(&[merged], &children[1..])
                } else {
                    // `merged` grew to `right`'s height; splice in its children.
                    merge_children(merged.children(), &children[1..])
                }
            }
            std::cmp::Ordering::Greater => {
                let children = left.children();
                let (last, rest) = children.split_last().expect("internal has children");
                let merged = Node::concat(last.clone(), right);
                if merged.height() == height_left - 1 {
                    merge_nodes(rest, &[merged])
                } else {
                    merge_children(rest, merged.children())
                }
            }
        }
    }

    /// Writes the full content in document order, `O(height)` stack, no buffer.
    pub(super) fn write_to(&self, writer: &mut dyn std::io::Write) -> std::io::Result<()> {
        match self {
            Node::Leaf(leaf) => writer.write_all(leaf.chunk.as_bytes()),
            Node::Internal(internal) => {
                for child in &internal.children {
                    child.write_to(writer)?;
                }
                Ok(())
            }
        }
    }
}

/// Splits a leaf summary at byte `at`, scanning the smaller half and deriving
/// the other by subtraction (so a huge leaf's split stays bounded).
fn split_summary(total: TextSummary, text: &str, at: usize) -> (TextSummary, TextSummary) {
    if at * 2 <= total.bytes {
        let left = TextSummary::of(&text[..at]);
        (left, total - left)
    } else {
        let right = TextSummary::of(&text[at..]);
        (total - right, right)
    }
}

/// A node from a child slice: empty for none, the child itself for one (so no
/// one-child internal forms), an internal for several.
fn from_children_or_empty(children: &[Node]) -> Node {
    match children.len() {
        0 => Node::empty(),
        1 => children[0].clone(),
        _ => Node::from_children(children.to_vec()),
    }
}

/// Combines two same-height child lists into a balanced node one level up,
/// splitting into two half-full nodes when they overflow `B_MAX`.
fn merge_children(left: &[Node], right: &[Node]) -> Node {
    let total = left.len() + right.len();
    let mut all = Vec::with_capacity(total);
    all.extend_from_slice(left);
    all.extend_from_slice(right);
    if total <= B_MAX {
        Node::from_children(all)
    } else {
        let split = total / 2;
        let right_children = all.split_off(split);
        Node::from_children(vec![
            Node::from_children(all),
            Node::from_children(right_children),
        ])
    }
}

/// Like [`merge_children`] but for two same-height nodes given as `&[Node]`
/// inputs that may be empty (used by `concat`'s equal-height internal case).
fn merge_nodes(left: &[Node], right: &[Node]) -> Node {
    if left.is_empty() {
        return from_children_or_empty(right);
    }
    if right.is_empty() {
        return from_children_or_empty(left);
    }
    merge_children(left, right)
}

/// Merges two leaves: one leaf if they fit a leaf, else two leaves under a
/// parent. Combining loses sharing (becomes `Owned`), but only happens for small
/// adjacent leaves near an edit, never during a fresh build.
fn merge_leaves(left: Node, right: Node) -> Node {
    let (left_leaf, right_leaf) = (left.leaf_ref(), right.leaf_ref());
    let combined = left_leaf.summary.bytes + right_leaf.summary.bytes;
    if combined <= LEAF_MAX_BYTES {
        let mut text = String::with_capacity(combined);
        text.push_str(left_leaf.chunk.as_str());
        text.push_str(right_leaf.chunk.as_str());
        let summary = left_leaf.summary + right_leaf.summary;
        Node::leaf(Chunk::Owned(Arc::from(text.as_str())), summary)
    } else {
        Node::from_children(vec![left, right])
    }
}

/// Bottom-up bulk build of a balanced tree from a flat list of equal-height
/// nodes. `O(n / B)` and perfectly balanced — the fast load path (no repeated
/// `concat`). Groups never leave a final group below `B_MIN`.
fn build_balanced(mut nodes: Vec<Node>) -> Node {
    if nodes.is_empty() {
        return Node::empty();
    }
    while nodes.len() > 1 {
        let mut next = Vec::with_capacity(nodes.len() / B_MIN + 1);
        let mut index = 0;
        while index < nodes.len() {
            let take = group_size(nodes.len() - index);
            let group = nodes[index..index + take].to_vec();
            next.push(Node::from_children(group));
            index += take;
        }
        nodes = next;
    }
    nodes.pop().expect("non-empty")
}

/// How many of `remaining` nodes to place in the next group: `B_MAX`, unless
/// that would strand a final group below `B_MIN`, in which case borrow enough to
/// keep both groups `>= B_MIN`.
fn group_size(remaining: usize) -> usize {
    if remaining <= B_MAX {
        remaining
    } else if remaining < B_MAX + B_MIN {
        remaining - B_MIN
    } else {
        B_MAX
    }
}

/// Picks a chunk end `> start` on a UTF-8 char boundary, aiming for `chunk`
/// bytes. Ported verbatim from the previous piece-table implementation: it backs
/// off to the boundary at or before the target, then extends forward if a single
/// char is wider than the whole chunk (only with the tiny caps tests use).
fn next_chunk_end(bytes: &[u8], start: usize, chunk: usize) -> usize {
    let len = bytes.len();
    let target = (start + chunk).min(len);
    if target >= len {
        return len;
    }
    let mut end = target;
    while end > start && !is_char_boundary(bytes[end]) {
        end -= 1;
    }
    if end > start {
        return end;
    }
    let mut end = target;
    while end < len && !is_char_boundary(bytes[end]) {
        end += 1;
    }
    end
}

/// Whether `byte` begins a UTF-8 code point (i.e. is not a continuation byte).
fn is_char_boundary(byte: u8) -> bool {
    byte & 0xC0 != 0x80
}

#[cfg(test)]
impl Node {
    /// Total bytes held in `Owned` leaves (inserted content); `Shared` views into
    /// the original count as zero. The rope analogue of the old add buffer's
    /// length — used to prove a large delete/undo copies no original content.
    pub(super) fn owned_byte_count(&self) -> usize {
        match self {
            Node::Leaf(leaf) => match &leaf.chunk {
                Chunk::Owned(text) => text.len(),
                Chunk::Shared { .. } => 0,
            },
            Node::Internal(internal) => internal.children.iter().map(Node::owned_byte_count).sum(),
        }
    }

    /// Total nodes reachable from this root — used to prove the live graph stays
    /// bounded across repeated edit/undo cycles.
    pub(super) fn node_count(&self) -> usize {
        match self {
            Node::Leaf(_) => 1,
            Node::Internal(internal) => {
                1 + internal
                    .children
                    .iter()
                    .map(Node::node_count)
                    .sum::<usize>()
            }
        }
    }

    /// The largest leaf, in bytes. Bounded by `LEAF_MAX_BYTES` even for a single
    /// enormous line — the structural property that keeps a within-leaf scan (and
    /// thus `position_for_line_column` on a giant line) bounded.
    pub(super) fn max_leaf_bytes(&self) -> usize {
        match self {
            Node::Leaf(leaf) => leaf.chunk.len(),
            Node::Internal(internal) => internal
                .children
                .iter()
                .map(Node::max_leaf_bytes)
                .max()
                .unwrap_or(0),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Wraps owned bytes as a `ContentBytes` backing for tests.
    struct Bytes(Vec<u8>);

    impl ContentBytes for Bytes {
        fn as_bytes(&self) -> &[u8] {
            &self.0
        }
    }

    fn backing(text: &str) -> Arc<dyn ContentBytes> {
        Arc::new(Bytes(text.as_bytes().to_vec()))
    }

    fn build(text: &str, cap: usize) -> Node {
        Node::from_backing(backing(text), cap)
    }

    fn collect(node: &Node) -> String {
        let mut out = Vec::new();
        node.write_to(&mut out).expect("write");
        String::from_utf8(out).expect("utf-8")
    }

    /// Verifies every structural invariant and returns the node's height.
    fn check(node: &Node) -> u8 {
        match node {
            Node::Leaf(leaf) => {
                assert_eq!(
                    leaf.summary,
                    TextSummary::of(leaf.chunk.as_str()),
                    "leaf summary must match its content"
                );
                assert!(
                    leaf.chunk.len() <= LEAF_MAX_BYTES,
                    "leaf of {} bytes exceeds the cap",
                    leaf.chunk.len()
                );
                0
            }
            Node::Internal(internal) => {
                assert!(
                    internal.children.len() >= 2 && internal.children.len() <= B_MAX,
                    "internal child count {} out of range",
                    internal.children.len()
                );
                let mut summary = TextSummary::default();
                for child in &internal.children {
                    let child_height = check(child);
                    assert_eq!(
                        child_height + 1,
                        internal.height,
                        "children must be one level below their parent"
                    );
                    summary += child.summary();
                }
                assert_eq!(
                    summary, internal.summary,
                    "internal summary must be the sum"
                );
                internal.height
            }
        }
    }

    #[test]
    fn summary_is_a_monoid() {
        let a = TextSummary::of("aあ");
        let b = TextSummary::of("𝄞\n");
        let c = TextSummary::of("bc");
        assert_eq!((a + b) + c, a + (b + c), "associative");
        assert_eq!(a + TextSummary::default(), a, "identity");
        assert_eq!((a + b) - b, a, "subtraction inverts addition");
    }

    #[test]
    fn summary_counts_utf16_and_line_breaks() {
        let summary = TextSummary::of("a\r\n𝄞\n");
        assert_eq!(summary.bytes, "a\r\n𝄞\n".len());
        assert_eq!(summary.chars, 5); // a \r \n 𝄞 \n
        assert_eq!(summary.utf16, 1 + 1 + 1 + 2 + 1);
        assert_eq!(summary.line_breaks, 2); // only the two '\n'
    }

    #[test]
    fn build_round_trips_content_and_summary() {
        let text = "alpha\nbeta\r\nγδε𝄞ζ\nlast line, no newline";
        for cap in [1, 2, 3, 4, 7, 16, 4096] {
            let node = build(text, cap);
            check(&node);
            assert_eq!(collect(&node), text, "content at cap {cap}");
            assert_eq!(
                node.summary(),
                TextSummary::of(text),
                "summary at cap {cap}"
            );
        }
    }

    #[test]
    fn build_handles_empty_and_single_char() {
        let empty = build("", 4);
        assert!(empty.is_empty());
        assert_eq!(empty.height(), 0);
        assert_eq!(collect(&empty), "");

        let one = build("𝄞", 4);
        check(&one);
        assert_eq!(collect(&one), "𝄞");
        assert_eq!(one.summary().utf16, 2);
    }

    #[test]
    fn split_round_trips_at_every_char_boundary() {
        let text = "ab\r\ncδe\n𝄞z";
        let node = build(text, 3);
        let mut at = 0;
        while at <= text.len() {
            if text.is_char_boundary(at) {
                let (left, right) = node.split(at);
                check(&left);
                check(&right);
                assert_eq!(collect(&left), &text[..at], "left at {at}");
                assert_eq!(collect(&right), &text[at..], "right at {at}");
                assert_eq!(left.summary(), TextSummary::of(&text[..at]));
                assert_eq!(right.summary(), TextSummary::of(&text[at..]));
            }
            at += 1;
        }
    }

    #[test]
    fn concat_of_split_is_the_original() {
        let text = "0123456789abcdefγδε𝄞\nlast";
        let node = build(text, 2);
        for at in 0..=text.len() {
            if !text.is_char_boundary(at) {
                continue;
            }
            let (left, right) = node.split(at);
            let joined = Node::concat(left, right);
            check(&joined);
            assert_eq!(collect(&joined), text, "rejoined at {at}");
            assert_eq!(joined.summary(), TextSummary::of(text));
        }
    }

    #[test]
    fn concat_with_empty_is_identity() {
        let node = build("hello", 2);
        let left = Node::concat(Node::empty(), node.clone());
        let right = Node::concat(node.clone(), Node::empty());
        assert_eq!(collect(&left), "hello");
        assert_eq!(collect(&right), "hello");
    }

    #[test]
    fn repeated_concat_stays_balanced_and_shallow() {
        // Append many small ropes; height must stay logarithmic, never linear.
        let mut node = Node::empty();
        for index in 0..2000 {
            let piece = Node::from_str(&format!("line {index}\n"));
            node = Node::concat(node, piece);
        }
        check(&node);
        // ~2000 leaves at fan-out 12 → height ~3-4; a linear chain would be huge.
        assert!(node.height() <= 6, "height grew to {}", node.height());
        assert_eq!(node.summary().line_breaks, 2000);
    }

    #[test]
    fn shared_leaves_do_not_copy_the_backing() {
        // Building over a backing yields Shared leaves; only their summaries are
        // computed. (Owned content would appear only after edits.)
        let node = build(&"x".repeat(100_000), 4096);
        check(&node);
        fn assert_all_shared(node: &Node) {
            match node {
                Node::Leaf(leaf) => {
                    assert!(
                        matches!(leaf.chunk, Chunk::Shared { .. }),
                        "fresh leaf is shared"
                    )
                }
                Node::Internal(internal) => internal.children.iter().for_each(assert_all_shared),
            }
        }
        assert_all_shared(&node);
    }

    #[test]
    fn splitting_an_owned_leaf_copies_each_half() {
        let node = Node::from_str("hello world");
        let (left, right) = node.split(5);
        assert_eq!(collect(&left), "hello");
        assert_eq!(collect(&right), " world");
        check(&left);
        check(&right);
    }
}
