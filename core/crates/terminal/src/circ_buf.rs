//! Circular storage used by terminal search windows.

use std::fmt;

// ghostty: datastruct/circ_buf.zig:5
// Rust deviation: Ghostty accepts a comptime fill value and uses `undefined`
// for metadata slots. Safe Rust initializes every spare slot with `Default`;
// callers still overwrite a slot before it becomes logically visible.
#[derive(Clone)]
pub(crate) struct CircBuf<T: Default + Clone> {
    storage: Vec<T>,
    head: usize,
    tail: usize,
    full: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct CircBufFull;

impl fmt::Display for CircBufFull {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("circular buffer is full")
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
// ghostty: datastruct/circ_buf.zig:28
pub(crate) enum Direction {
    Forward,
    Reverse,
}

// Rust deviation: Ghostty's iterator copies a slice-owning Zig value. The
// Rust iterator borrows the buffer, avoiding a clone while preserving its
// snapshot of the logical head/tail state for the duration of the borrow.
pub(crate) struct Iterator<'a, T: Default + Clone> {
    buffer: &'a CircBuf<T>,
    pub(crate) index: usize,
    direction: Direction,
}

impl<'a, T: Default + Clone> Iterator<'a, T> {
    // ghostty: datastruct/circ_buf.zig:31
    pub(crate) fn next(&mut self) -> Option<&'a T> {
        if self.index >= self.buffer.len() {
            return None;
        }

        let tail_index = match self.direction {
            Direction::Forward => self.index,
            Direction::Reverse => self.buffer.len() - self.index - 1,
        };
        let storage_index = (self.buffer.tail + tail_index) % self.buffer.capacity();
        self.index += 1;
        self.buffer.storage.get(storage_index)
    }

    // ghostty: datastruct/circ_buf.zig:47
    pub(crate) fn seek_by(&mut self, amount: isize) {
        if amount >= 0 {
            self.index = self.index.saturating_add(amount as usize);
        } else {
            self.index = self.index.saturating_sub(amount.unsigned_abs());
        }
    }

    // ghostty: datastruct/circ_buf.zig:57
    #[cfg_attr(
        not(test),
        expect(dead_code, reason = "ported upstream iterator surface")
    )]
    pub(crate) fn reset(&mut self) {
        self.index = 0;
    }
}

impl<T: Default + Clone> CircBuf<T> {
    // ghostty: datastruct/circ_buf.zig:64
    pub(crate) fn new(size: usize) -> Self {
        Self {
            storage: vec![T::default(); size],
            head: 0,
            tail: 0,
            full: size == 0,
        }
    }

    // ghostty: datastruct/circ_buf.zig:84
    #[cfg_attr(
        not(test),
        expect(dead_code, reason = "ported API used by later search layers")
    )]
    pub(crate) fn append(&mut self, value: T) -> Result<(), CircBufFull> {
        if self.full {
            return Err(CircBufFull);
        }
        self.append_assume_capacity(value);
        Ok(())
    }

    // ghostty: datastruct/circ_buf.zig:94
    pub(crate) fn append_assume_capacity(&mut self, value: T) {
        debug_assert!(!self.full);
        self.storage[self.head] = value;
        self.head += 1;
        if self.head >= self.storage.len() {
            self.head = 0;
        }
        self.full = self.head == self.tail;
    }

    // ghostty: datastruct/circ_buf.zig:104
    pub(crate) fn append_slice_assume_capacity(&mut self, values: &[T]) {
        if values.is_empty() {
            return;
        }
        let (first, second) = self.get_mut_slices(self.len(), values.len());
        let split = first.len();
        first.clone_from_slice(&values[..split]);
        second.clone_from_slice(&values[split..]);
    }

    // ghostty: datastruct/circ_buf.zig:116
    pub(crate) fn clear(&mut self) {
        self.head = 0;
        self.tail = 0;
        self.full = false;
    }

    // ghostty: datastruct/circ_buf.zig:124
    pub(crate) fn iterator(&self, direction: Direction) -> Iterator<'_, T> {
        Iterator {
            buffer: self,
            index: 0,
            direction,
        }
    }

    // ghostty: datastruct/circ_buf.zig:133
    #[cfg_attr(
        not(test),
        expect(dead_code, reason = "ported upstream CircBuf surface")
    )]
    pub(crate) fn first(&self) -> Option<&T> {
        let mut iterator = self.iterator(Direction::Forward);
        iterator.next()
    }

    // ghostty: datastruct/circ_buf.zig:142
    #[cfg_attr(
        not(test),
        expect(dead_code, reason = "ported upstream CircBuf surface")
    )]
    pub(crate) fn last(&self) -> Option<&T> {
        let mut iterator = self.iterator(Direction::Reverse);
        iterator.next()
    }

    // ghostty: datastruct/circ_buf.zig:151
    pub(crate) fn ensure_unused_capacity(&mut self, amount: usize) {
        let new_capacity = self.len().saturating_add(amount);
        if new_capacity > self.capacity() {
            self.resize(new_capacity);
        }
    }

    // ghostty: datastruct/circ_buf.zig:163
    pub(crate) fn resize(&mut self, size: usize) {
        self.rotate_to_zero();

        let previous_len = self.len();
        let previous_capacity = self.storage.len();
        self.storage.resize(size, T::default());
        self.tail = 0;

        if size == 0 {
            self.head = 0;
            self.full = true;
        } else if size <= previous_len {
            self.head = previous_len.min(size) % size;
            self.full = previous_len >= size;
        } else if size > previous_capacity {
            self.head = previous_len;
            self.full = false;
        }
    }

    // ghostty: datastruct/circ_buf.zig:188
    fn rotate_to_zero(&mut self) {
        if self.tail == 0 {
            return;
        }

        let len = self.len();
        self.storage.rotate_left(self.tail);
        self.head = len % self.storage.len();
        self.tail = 0;
    }

    // ghostty: datastruct/circ_buf.zig:204
    #[cfg_attr(
        not(test),
        expect(dead_code, reason = "ported upstream CircBuf surface")
    )]
    pub(crate) fn is_empty(&self) -> bool {
        !self.full && self.head == self.tail
    }

    // ghostty: datastruct/circ_buf.zig:21
    #[cfg_attr(
        not(test),
        expect(dead_code, reason = "ported upstream CircBuf surface")
    )]
    pub(crate) fn is_full(&self) -> bool {
        self.full
    }

    // ghostty: datastruct/circ_buf.zig:211
    pub(crate) fn capacity(&self) -> usize {
        self.storage.len()
    }

    // ghostty: datastruct/circ_buf.zig:216
    pub(crate) fn len(&self) -> usize {
        if self.full {
            return self.storage.len();
        }
        if self.head >= self.tail {
            return self.head - self.tail;
        }
        self.storage.len() - (self.tail - self.head)
    }

    // ghostty: datastruct/circ_buf.zig:226
    pub(crate) fn delete_oldest(&mut self, count: usize) {
        debug_assert!(count <= self.storage.len());
        if count == 0 {
            return;
        }

        {
            let (first, second) = self.get_mut_slices(0, count);
            first.fill(T::default());
            second.fill(T::default());
        }

        self.tail += self.len().min(count);
        if self.tail >= self.storage.len() {
            self.tail -= self.storage.len();
        }
        self.full = false;
    }

    // ghostty: datastruct/circ_buf.zig:253
    pub(crate) fn get_mut_slices(
        &mut self,
        offset: usize,
        slice_len: usize,
    ) -> (&mut [T], &mut [T]) {
        if slice_len == 0 {
            let (left, right) = self.storage.split_at_mut(0);
            return (&mut left[..0], &mut right[..0]);
        }

        debug_assert!(offset <= self.capacity().saturating_sub(slice_len));
        let end_offset = offset + slice_len;
        if end_offset > self.len() {
            self.advance(end_offset - self.len());
        }

        let start_index = self.storage_offset(offset);
        let end_index = self.storage_offset(end_offset - 1);
        if end_index >= start_index {
            let (_, tail) = self.storage.split_at_mut(start_index);
            let (first, remainder) = tail.split_at_mut(slice_len);
            return (first, &mut remainder[..0]);
        }

        let (prefix, suffix) = self.storage.split_at_mut(start_index);
        let second_len = end_index + 1;
        (suffix, &mut prefix[..second_len])
    }

    // ghostty: datastruct/circ_buf.zig:296
    fn advance(&mut self, amount: usize) {
        debug_assert!(amount <= self.storage.len() - self.len());
        self.head += amount;
        if self.head >= self.storage.len() {
            self.head -= self.storage.len();
        }
        if self.full {
            self.tail = self.head;
        }
        self.full = self.head == self.tail;
    }

    // ghostty: datastruct/circ_buf.zig:313
    fn storage_offset(&self, offset: usize) -> usize {
        debug_assert!(offset < self.storage.len());
        let candidate = self.tail + offset;
        if candidate < self.storage.len() {
            candidate
        } else {
            candidate - self.storage.len()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    // ghostty: unnamed test declaration (circ_buf.zig:313)
    fn circ_buf_starts_empty() {
        let buffer = CircBuf::<u8>::new(12);
        assert!(buffer.is_empty());
        assert_eq!(buffer.len(), 0);
    }

    #[test]
    // ghostty: "CircBuf append" (circ_buf.zig:325)
    fn append_rejects_values_when_full() {
        let mut buffer = CircBuf::<u8>::new(3);
        assert_eq!(buffer.append(1), Ok(()));
        assert_eq!(buffer.append(2), Ok(()));
        assert_eq!(buffer.append(3), Ok(()));
        assert_eq!(buffer.append(4), Err(CircBufFull));
        buffer.delete_oldest(1);
        assert_eq!(buffer.append(4), Ok(()));
        assert_eq!(buffer.append(5), Err(CircBufFull));
    }

    #[test]
    // ghostty: "CircBuf forward iterator" (circ_buf.zig:342)
    fn forward_iterator_preserves_logical_order() {
        let mut buffer = CircBuf::<u8>::new(3);
        assert_eq!(buffer.iterator(Direction::Forward).next(), None);
        buffer.append(1).unwrap();
        buffer.append(2).unwrap();
        assert_eq!(values(&buffer, Direction::Forward), vec![1, 2]);
        buffer.append(3).unwrap();
        let mut iterator = buffer.iterator(Direction::Forward);
        iterator.seek_by(2);
        assert_eq!(iterator.next(), Some(&3));
        iterator.reset();
        assert_eq!(iterator.next(), Some(&1));
        buffer.delete_oldest(1);
        buffer.append(4).unwrap();
        assert_eq!(values(&buffer, Direction::Forward), vec![2, 3, 4]);
    }

    #[test]
    // ghostty: "CircBuf reverse iterator" (circ_buf.zig:388)
    fn reverse_iterator_preserves_reverse_logical_order() {
        let mut buffer = CircBuf::<u8>::new(3);
        assert_eq!(buffer.iterator(Direction::Reverse).next(), None);
        buffer.append(1).unwrap();
        buffer.append(2).unwrap();
        assert_eq!(values(&buffer, Direction::Reverse), vec![2, 1]);
        buffer.append(3).unwrap();
        assert_eq!(values(&buffer, Direction::Reverse), vec![3, 2, 1]);
        buffer.delete_oldest(1);
        buffer.append(4).unwrap();
        assert_eq!(values(&buffer, Direction::Reverse), vec![4, 3, 2]);
    }

    #[test]
    // ghostty: "CircBuf first/last" (circ_buf.zig:434)
    fn first_and_last_return_oldest_and_newest() {
        let mut buffer = CircBuf::<u8>::new(3);
        buffer.append_slice_assume_capacity(&[1, 2, 3]);
        assert_eq!(buffer.first(), Some(&1));
        assert_eq!(buffer.last(), Some(&3));
    }

    #[test]
    // ghostty: "CircBuf first/last empty" (circ_buf.zig:449)
    fn first_and_last_are_none_for_zero_capacity() {
        let buffer = CircBuf::<u8>::new(0);
        assert_eq!(buffer.first(), None);
        assert_eq!(buffer.last(), None);
    }

    #[test]
    // ghostty: "CircBuf first/last empty with cap" (circ_buf.zig:461)
    fn first_and_last_are_none_for_empty_buffer_with_capacity() {
        let buffer = CircBuf::<u8>::new(3);
        assert_eq!(buffer.first(), None);
        assert_eq!(buffer.last(), None);
    }

    #[test]
    // ghostty: "CircBuf append slice" (circ_buf.zig:473)
    fn append_slice_writes_all_values() {
        let mut buffer = CircBuf::<u8>::new(5);
        buffer.append_slice_assume_capacity(b"hello");
        assert_eq!(values(&buffer, Direction::Forward), b"hello");
    }

    #[test]
    // ghostty: "CircBuf append slice with wrap" (circ_buf.zig:493)
    fn append_slice_wraps_at_storage_boundary() {
        let mut buffer = CircBuf::<u8>::new(4);
        let capacity = buffer.capacity();
        let _ = buffer.get_mut_slices(0, capacity);
        assert!(buffer.is_full());
        assert_eq!(buffer.len(), 4);
        buffer.delete_oldest(2);
        assert!(!buffer.is_full());
        assert_eq!(buffer.len(), 2);
        buffer.append_slice_assume_capacity(b"AB");
        assert_eq!(values(&buffer, Direction::Forward), vec![0, 0, b'A', b'B']);
    }

    #[test]
    // ghostty: "CircBuf getPtrSlice fits" (circ_buf.zig:522)
    fn mutable_slices_fit_without_wrapping() {
        let mut buffer = CircBuf::<u8>::new(12);
        let (first, second) = buffer.get_mut_slices(0, 11);
        assert_eq!((first.len(), second.len()), (11, 0));
        assert_eq!(buffer.len(), 11);
    }

    #[test]
    // ghostty: "CircBuf getPtrSlice wraps" (circ_buf.zig:536)
    fn mutable_slices_split_across_storage_boundary() {
        let mut buffer = CircBuf::<u8>::new(4);
        let capacity = buffer.capacity();
        let _ = buffer.get_mut_slices(0, capacity);
        assert!(buffer.is_full());
        assert_eq!(buffer.len(), 4);
        buffer.delete_oldest(2);
        assert!(!buffer.is_full());
        assert_eq!(buffer.len(), 2);
        {
            let (first, second) = buffer.get_mut_slices(0, 2);
            assert_eq!((first.len(), second.len()), (2, 0));
            first.copy_from_slice(&[1, 2]);
        }
        assert_eq!(buffer.len(), 2);
        {
            let (first, second) = buffer.get_mut_slices(2, 2);
            assert_eq!((first.len(), second.len()), (2, 0));
            assert_eq!(first, &[0, 0]);
            first.copy_from_slice(&[3, 4]);
        }
        assert_eq!(buffer.len(), 4);
        {
            let (first, second) = buffer.get_mut_slices(0, 4);
            assert_eq!((first, second), (&mut [1, 2][..], &mut [3, 4][..]));
        }
        assert_eq!(buffer.len(), 4);
    }

    #[test]
    // ghostty: "CircBuf rotateToZero" (circ_buf.zig:592)
    fn rotate_to_zero_is_noop_when_aligned() {
        let mut buffer = CircBuf::<u8>::new(12);
        let _ = buffer.get_mut_slices(0, 11);
        buffer.rotate_to_zero();
        assert_eq!((buffer.tail, buffer.head), (0, 11));
    }

    #[test]
    // ghostty: "CircBuf rotateToZero offset" (circ_buf.zig:604)
    fn rotate_to_zero_aligns_offset_data() {
        let mut buffer = CircBuf::<u8>::new(4);
        let _ = buffer.get_mut_slices(0, 3);
        assert_eq!(buffer.len(), 3);
        buffer.delete_oldest(2);
        assert!(!buffer.is_full());
        assert_eq!(buffer.len(), 1);
        assert!(buffer.tail > 0 && buffer.head >= buffer.tail);
        buffer.rotate_to_zero();
        assert_eq!((buffer.tail, buffer.head), (0, 1));
    }

    #[test]
    // ghostty: "CircBuf rotateToZero wraps" (circ_buf.zig:628)
    fn rotate_to_zero_preserves_wrapped_values() {
        let mut buffer = CircBuf::<u8>::new(4);
        let _ = buffer.get_mut_slices(0, 3);
        assert_eq!(buffer.len(), 3);
        assert_eq!((buffer.tail, buffer.head), (0, 3));
        buffer.delete_oldest(3);
        assert_eq!(buffer.len(), 0);
        assert_eq!((buffer.tail, buffer.head), (3, 3));
        {
            let (first, second) = buffer.get_mut_slices(0, 3);
            first[0] = 1;
            second.copy_from_slice(&[2, 3]);
        }
        assert_eq!(buffer.len(), 3);
        assert_eq!((buffer.tail, buffer.head), (3, 2));
        buffer.rotate_to_zero();
        assert_eq!(values(&buffer, Direction::Forward), vec![1, 2, 3]);
        assert_eq!((buffer.tail, buffer.head), (0, 3));
    }

    #[test]
    // ghostty: "CircBuf rotateToZero full no wrap" (circ_buf.zig:668)
    fn rotate_to_zero_preserves_full_wrapped_values() {
        let mut buffer = CircBuf::<u8>::new(4);
        let _ = buffer.get_mut_slices(0, 3);
        buffer.delete_oldest(3);
        {
            let (first, second) = buffer.get_mut_slices(0, 4);
            first[0] = 1;
            second.copy_from_slice(&[2, 3, 4]);
        }
        assert!(buffer.is_full());
        buffer.rotate_to_zero();
        assert!(buffer.is_full());
        assert_eq!((buffer.tail, buffer.head), (0, 0));
        assert_eq!(values(&buffer, Direction::Forward), vec![1, 2, 3, 4]);
    }

    #[test]
    // ghostty: "CircBuf resize grow from zero" (circ_buf.zig:706)
    fn resize_grows_from_zero_capacity() {
        let mut buffer = CircBuf::<u8>::new(0);
        assert!(buffer.is_full());
        buffer.resize(2);
        assert!(!buffer.is_full());
        assert_eq!((buffer.len(), buffer.capacity()), (0, 2));
        buffer.append_slice_assume_capacity(&[1, 2]);
        assert_eq!(values(&buffer, Direction::Forward), vec![1, 2]);
    }

    #[test]
    // ghostty: "CircBuf resize grow" (circ_buf.zig:731)
    fn resize_grow_preserves_values() {
        let mut buffer = CircBuf::<u8>::new(4);
        buffer.append_slice_assume_capacity(&[1, 2, 3, 4]);
        buffer.resize(6);
        assert!(!buffer.is_full());
        assert_eq!((buffer.len(), buffer.capacity()), (4, 6));
        assert_eq!(values(&buffer, Direction::Forward), vec![1, 2, 3, 4]);
    }

    #[test]
    // ghostty: "CircBuf resize shrink" (circ_buf.zig:764)
    fn resize_shrink_retains_oldest_values() {
        let mut buffer = CircBuf::<u8>::new(4);
        buffer.append_slice_assume_capacity(&[1, 2, 3, 4]);
        buffer.resize(3);
        assert!(buffer.is_full());
        assert_eq!((buffer.len(), buffer.capacity()), (3, 3));
        assert_eq!(values(&buffer, Direction::Forward), vec![1, 2, 3]);
    }

    #[test]
    // ghostty: "CircBuf append empty slice" (circ_buf.zig:796)
    fn append_empty_slice_is_noop() {
        let mut buffer = CircBuf::<u8>::new(5);
        buffer.append_slice_assume_capacity(&[]);
        assert_eq!(buffer.len(), 0);
        assert!(!buffer.is_full());
        buffer.append_slice_assume_capacity(b"hi");
        assert_eq!(buffer.len(), 2);
        buffer.append_slice_assume_capacity(&[]);
        assert_eq!(buffer.len(), 2);
        assert_eq!(values(&buffer, Direction::Forward), b"hi");
    }

    #[test]
    // ghostty: "CircBuf getPtrSlice zero length" (circ_buf.zig:818)
    fn mutable_slices_zero_length_is_noop() {
        let mut buffer = CircBuf::<u8>::new(5);
        {
            let (first, second) = buffer.get_mut_slices(0, 0);
            assert_eq!((first.len(), second.len()), (0, 0));
        }
        assert_eq!(buffer.len(), 0);
        buffer.append_slice_assume_capacity(b"abc");
        assert_eq!(buffer.len(), 3);
        {
            let (first, second) = buffer.get_mut_slices(0, 0);
            assert_eq!((first.len(), second.len()), (0, 0));
        }
        assert_eq!(buffer.len(), 3);
    }

    #[test]
    // ghostty: "CircBuf deleteOldest zero" (circ_buf.zig:843)
    fn delete_oldest_zero_is_noop() {
        let mut buffer = CircBuf::<u8>::new(5);
        buffer.delete_oldest(0);
        assert_eq!(buffer.len(), 0);
        buffer.append_slice_assume_capacity(b"hello");
        assert_eq!(buffer.len(), 5);
        buffer.delete_oldest(0);
        assert_eq!(buffer.len(), 5);
        assert_eq!(values(&buffer, Direction::Forward), b"hello");
    }

    fn values<T: Default + Clone + Copy>(buffer: &CircBuf<T>, direction: Direction) -> Vec<T> {
        let mut iterator = buffer.iterator(direction);
        let mut result = Vec::new();
        while let Some(value) = iterator.next() {
            result.push(*value);
        }
        result
    }
}
