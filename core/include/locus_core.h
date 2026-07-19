#ifndef LOCUS_CORE_H
#define LOCUS_CORE_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint32_t LocusStatus;

#define LOCUS_STATUS_OK ((LocusStatus)0u)
#define LOCUS_STATUS_INVALID_ARGUMENT ((LocusStatus)1u)
#define LOCUS_STATUS_NOT_FOUND ((LocusStatus)2u)
#define LOCUS_STATUS_NOT_DIRECTORY ((LocusStatus)3u)
#define LOCUS_STATUS_READ_DIRECTORY ((LocusStatus)4u)
#define LOCUS_STATUS_READ_ENTRY ((LocusStatus)5u)
#define LOCUS_STATUS_READ_METADATA ((LocusStatus)6u)

/*
 * Status policy:
 * - LOCUS_STATUS_OK is the only success value.
 * - Any other known or unknown status value must be treated as a failure.
 * - Callers should include a default failure branch because future ABI versions
 *   may add status values.
 */

typedef uint32_t LocusWorkspaceEntryKind;

#define LOCUS_WORKSPACE_ENTRY_DIRECTORY ((LocusWorkspaceEntryKind)1u)
#define LOCUS_WORKSPACE_ENTRY_FILE ((LocusWorkspaceEntryKind)2u)
#define LOCUS_WORKSPACE_ENTRY_SYMLINK ((LocusWorkspaceEntryKind)3u)
#define LOCUS_WORKSPACE_ENTRY_OTHER ((LocusWorkspaceEntryKind)4u)
#define LOCUS_WORKSPACE_ENTRY_SYMLINK_DIRECTORY ((LocusWorkspaceEntryKind)5u)
#define LOCUS_WORKSPACE_ENTRY_SYMLINK_FILE ((LocusWorkspaceEntryKind)6u)

typedef uint32_t LocusFileType;

#define LOCUS_FILE_TYPE_MARKDOWN ((LocusFileType)1u)
#define LOCUS_FILE_TYPE_STRUCTURED_TEXT ((LocusFileType)2u)
#define LOCUS_FILE_TYPE_PDF ((LocusFileType)3u)
#define LOCUS_FILE_TYPE_OFFICE ((LocusFileType)4u)
#define LOCUS_FILE_TYPE_IMAGE ((LocusFileType)5u)
#define LOCUS_FILE_TYPE_AUDIO ((LocusFileType)6u)
#define LOCUS_FILE_TYPE_VIDEO ((LocusFileType)7u)
#define LOCUS_FILE_TYPE_PLAIN_TEXT ((LocusFileType)8u)
#define LOCUS_FILE_TYPE_CODE ((LocusFileType)9u)
#define LOCUS_FILE_TYPE_UNKNOWN ((LocusFileType)10u)

typedef struct LocusWorkspaceEntry {
    /* Borrowed UTF-8 strings. Valid only while the parent snapshot is alive. */
    const char *path;
    const char *name;
    LocusWorkspaceEntryKind kind;
    /*
     * Valid only when kind == LOCUS_WORKSPACE_ENTRY_FILE or
     * LOCUS_WORKSPACE_ENTRY_SYMLINK_FILE. Other entry kinds use
     * LOCUS_FILE_TYPE_UNKNOWN and callers should ignore this field.
     */
    LocusFileType file_type;
    /*
     * size_bytes is valid only when has_size_bytes is true. The default folder
     * listing keeps this false; callers should request or load extended
     * metadata only for contextual surfaces that need it.
     */
    bool has_size_bytes;
    uint64_t size_bytes;
    /*
     * modified_unix_seconds is valid only when has_modified_unix_seconds is
     * true. The default folder listing keeps this false. The value is seconds
     * relative to the Unix epoch.
     */
    bool has_modified_unix_seconds;
    int64_t modified_unix_seconds;
    bool readonly;
} LocusWorkspaceEntry;

typedef struct LocusWorkspacePartialError {
    LocusStatus status;
    /* Borrowed UTF-8 string. Valid only while the parent snapshot is alive. */
    const char *message;
} LocusWorkspacePartialError;

/*
 * Opaque Rust-owned snapshot handle. Callers must never allocate, free, copy, or
 * inspect this type directly; use the accessor and free functions below.
 */
typedef struct LocusWorkspaceSnapshot LocusWorkspaceSnapshot;

/**
 * Returns the ABI version implemented by this Rust FFI library.
 *
 * ABI compatibility is intentionally decided by locus_core_is_abi_compatible().
 * Callers should not duplicate compatibility logic in Swift or other native
 * shells.
 *
 * Version policy:
 * - Version 0 is invalid.
 * - Adding a new exported function without changing existing contracts does not
 *   require an ABI version bump.
 * - Changing or removing an exported symbol, argument type, return type, struct
 *   layout, memory ownership rule, string encoding rule, or error contract
 *   requires an ABI version bump.
 *
 * Ownership: value type; no release required.
 * Thread-safety: safe to call from any thread.
 */
uint32_t locus_core_abi_version(void);

/**
 * Returns whether the caller's expected ABI version is compatible with this
 * Rust FFI library.
 *
 * Compatibility policy for the current ABI version is exact match. Callers should treat a
 * false result as a startup integration failure and avoid calling broader FFI
 * APIs.
 *
 * Ownership: value type; no release required.
 * Thread-safety: safe to call from any thread.
 */
bool locus_core_is_abi_compatible(uint32_t expected);

/**
 * Returns the Rust core version string exposed through the FFI layer.
 *
 * The returned pointer is always non-null for a successfully loaded library.
 *
 * Ownership: borrowed static pointer; caller must not free it.
 * Encoding: UTF-8, NUL-terminated.
 * Lifetime: valid for the lifetime of the loaded library.
 * Thread-safety: safe to call from any thread.
 */
const char *locus_core_version(void);

/**
 * Returns details for the last top-level FFI failure on the current thread.
 *
 * locus_core_list_directory clears this message before running and updates it
 * when returning a non-OK status. Partial per-entry errors are reported through
 * LocusWorkspaceSnapshot instead of this channel.
 *
 * Ownership: borrowed thread-local pointer; caller must not free it.
 * Encoding: UTF-8, NUL-terminated.
 * Lifetime: valid until the next FFI call on the same thread.
 * Thread-safety: safe to call from any thread; values are thread-local.
 */
const char *locus_last_error_message(void);

/**
 * Lists the immediate children of a local folder.
 *
 * The function performs a shallow directory read only. It does not recursively
 * scan, parse, index, thumbnail, hash, or preview files.
 *
 * This default entry point omits extended size and modified-time values. Use
 * locus_core_list_directory_with_options when a contextual surface explicitly
 * needs those fields.
 *
 * On success, returns LOCUS_STATUS_OK and writes a Rust-owned snapshot to
 * out_snapshot. The caller must release that snapshot with
 * locus_workspace_snapshot_free().
 *
 * If some child entries cannot be read after the folder itself is opened, the
 * function still returns LOCUS_STATUS_OK. Readable entries are present in the
 * snapshot and per-entry failures are available through
 * locus_workspace_snapshot_partial_errors().
 *
 * On failure, returns a non-OK status and writes NULL to out_snapshot when
 * out_snapshot itself is non-NULL.
 *
 * Ownership: returned snapshot is owned by Rust and released by Rust.
 * Encoding: path input and returned strings are UTF-8, NUL-terminated.
 * Lifetime: returned entry/error pointers remain valid until snapshot release.
 * Thread-safety: safe to call from any thread; snapshot pointers must not be
 * used after release.
 */
LocusStatus locus_core_list_directory(
    const char *path,
    bool include_ignored,
    LocusWorkspaceSnapshot **out_snapshot
);

/**
 * Lists the immediate children of a local folder with explicit listing options.
 *
 * include_extended_metadata controls whether file size and modified-time
 * fields are populated. Keeping it false is the preferred default for the
 * name-first file browser.
 *
 * Ownership, encoding, lifetime, thread-safety, and error behavior match
 * locus_core_list_directory().
 */
LocusStatus locus_core_list_directory_with_options(
    const char *path,
    bool include_ignored,
    bool include_extended_metadata,
    LocusWorkspaceSnapshot **out_snapshot
);

/**
 * Returns the number of entries in a workspace snapshot.
 *
 * Ownership: borrowed snapshot pointer; no release required.
 * Thread-safety: safe to call from any thread while snapshot is alive.
 */
size_t locus_workspace_snapshot_entry_count(const LocusWorkspaceSnapshot *snapshot);

/**
 * Returns a borrowed pointer to the snapshot entry array, or NULL when empty.
 *
 * Ownership: borrowed pointer; caller must not free it.
 * Lifetime: valid until locus_workspace_snapshot_free(snapshot).
 * Thread-safety: safe to call from any thread while snapshot is alive.
 */
const LocusWorkspaceEntry *locus_workspace_snapshot_entries(
    const LocusWorkspaceSnapshot *snapshot
);

/**
 * Returns the number of partial errors in a workspace snapshot.
 *
 * Ownership: borrowed snapshot pointer; no release required.
 * Thread-safety: safe to call from any thread while snapshot is alive.
 */
size_t locus_workspace_snapshot_partial_error_count(
    const LocusWorkspaceSnapshot *snapshot
);

/**
 * Returns a borrowed pointer to the partial error array, or NULL when empty.
 *
 * Ownership: borrowed pointer; caller must not free it.
 * Lifetime: valid until locus_workspace_snapshot_free(snapshot).
 * Thread-safety: safe to call from any thread while snapshot is alive.
 */
const LocusWorkspacePartialError *locus_workspace_snapshot_partial_errors(
    const LocusWorkspaceSnapshot *snapshot
);

/**
 * Releases a Rust-owned workspace snapshot.
 *
 * Passing NULL is allowed and has no effect.
 *
 * Ownership: consumes snapshot and invalidates all borrowed pointers from it.
 * Thread-safety: safe to call from any thread when no other thread is using the
 * snapshot.
 */
void locus_workspace_snapshot_free(LocusWorkspaceSnapshot *snapshot);

/*
 * Text buffer API (added additively in ABI version 2).
 *
 * An arbitrary-size, editable UTF-8 text buffer. The buffer is the source of
 * truth for the editor; text never crosses the boundary as one giant string.
 * Statuses live in a 100+ band so they never collide with the workspace
 * statuses above. LOCUS_STATUS_OK (0) remains the only success value.
 *
 * Thread-safety: a given LocusTextBuffer handle is not internally synchronized,
 * but it obeys the standard readers-writer (shared-XOR-exclusive) rule, so a
 * caller may run any number of read-only calls on one handle concurrently from
 * different threads. The read-only calls are every accessor and snapshot getter
 * (line count, byte/UTF-16 length, revision, is-dirty, history byte length, the
 * position queries, and the line-range and UTF-16-range snapshots). Direct
 * locus_text_buffer_write_path also only reads the live buffer, so it follows
 * the same readers-writer rule: it may overlap other reads, but it must not
 * overlap edits or any other mutation on the same handle. Use the save-snapshot
 * API below for background saves while editing continues.
 * The mutating calls --
 * locus_text_buffer_insert_bytes, locus_text_buffer_delete,
 * locus_text_buffer_replace, locus_text_buffer_undo, locus_text_buffer_redo,
 * locus_text_buffer_mark_saved, locus_text_buffer_mark_saved_and_clear_history,
 * locus_text_buffer_set_history_byte_limit, locus_text_buffer_take_save_snapshot,
 * and locus_text_buffer_mark_saved_snapshot -- plus locus_text_buffer_free
 * require exclusive access: the caller must ensure no other call on the same
 * handle (read or write) overlaps them. Overlapping a mutation with any other
 * access is undefined behavior. To save without pausing edits,
 * take_save_snapshot captures an immutable clone under that exclusive access;
 * locus_text_buffer_snapshot_write_path then streams that clone (a separate
 * LocusTextBufferSnapshot handle, not the live buffer) to disk on a background
 * thread while the buffer is edited and rendered concurrently.
 */
#define LOCUS_TEXT_STATUS_INVALID_ARGUMENT ((LocusStatus)100u)
#define LOCUS_TEXT_STATUS_IO ((LocusStatus)101u)
#define LOCUS_TEXT_STATUS_NOT_UTF8 ((LocusStatus)102u)
#define LOCUS_TEXT_STATUS_INVALID_OFFSET ((LocusStatus)103u)
#define LOCUS_TEXT_STATUS_INVALID_RANGE ((LocusStatus)104u)
#define LOCUS_TEXT_STATUS_INVALID_LINE ((LocusStatus)105u)

/*
 * A buffer position in every coordinate the editor needs. char_index is the
 * Unicode scalar index (named to avoid the C keyword `char`).
 */
typedef struct LocusTextPosition {
  size_t byte;
  size_t char_index;
  size_t utf16;
  size_t line;
  size_t column_utf16;
} LocusTextPosition;

/*
 * The document span one undo or redo step rewrote, in the coordinates of the
 * document that step produced: the content before start_utf16 is identical on
 * both sides of the step; at that offset the step replaced old_len_utf16 UTF-16
 * units with new_len_utf16 units. Lets the platform update per-line caches
 * (such as the soft-wrap index) for just the rewritten lines instead of
 * rescanning the document.
 */
typedef struct LocusTextChange {
  size_t start_utf16;
  size_t old_len_utf16;
  size_t new_len_utf16;
} LocusTextChange;

/*
 * Opaque Rust-owned handles. Callers must never allocate, free, copy, or
 * inspect these directly; use the functions below.
 */
typedef struct LocusTextBuffer LocusTextBuffer;
typedef struct LocusTextSnapshot LocusTextSnapshot;
typedef struct LocusTextBufferSnapshot LocusTextBufferSnapshot;

/**
 * Opens a text file into a buffer. The file must be valid UTF-8; a non-UTF-8
 * file returns LOCUS_TEXT_STATUS_NOT_UTF8 so the caller can decode the bytes
 * itself and use locus_text_buffer_open_bytes.
 *
 * The file is read into an owned buffer, so a later truncation or replacement
 * by another process cannot fault the process; the caller is responsible for
 * bounding the file size before opening (a very large file is refused rather
 * than read into memory).
 *
 * Ownership: on LOCUS_STATUS_OK, writes a Rust-owned buffer to *out_buffer that
 * the caller releases exactly once with locus_text_buffer_free.
 */
LocusStatus locus_text_buffer_open(const char *path, LocusTextBuffer **out_buffer);

/**
 * Opens a buffer from already-UTF-8 bytes (bytes may be NULL only when len is
 * 0). The bytes are copied; the caller retains ownership of the input.
 *
 * Ownership: on LOCUS_STATUS_OK, writes a Rust-owned buffer to *out_buffer.
 */
LocusStatus locus_text_buffer_open_bytes(
    const uint8_t *bytes, size_t len, LocusTextBuffer **out_buffer);

/**
 * Releases a text buffer. Passing NULL is allowed and has no effect.
 *
 * Ownership: consumes the buffer; all snapshots borrowed from it must already
 * be freed.
 */
void locus_text_buffer_free(LocusTextBuffer *buffer);

/* Scalar queries. NULL returns 0 / false. */
size_t locus_text_buffer_line_count(const LocusTextBuffer *buffer);
size_t locus_text_buffer_byte_length(const LocusTextBuffer *buffer);
size_t locus_text_buffer_utf16_length(const LocusTextBuffer *buffer);
uint64_t locus_text_buffer_revision(const LocusTextBuffer *buffer);
bool locus_text_buffer_is_dirty(const LocusTextBuffer *buffer);
size_t locus_text_buffer_history_byte_length(const LocusTextBuffer *buffer);

/*
 * Sets the best-effort retained undo/redo byte budget. The latest undo record is
 * kept even if it alone exceeds the budget, so one-step undo does not disappear.
 */
LocusStatus locus_text_buffer_set_history_byte_limit(
    LocusTextBuffer *buffer, size_t byte_limit);

/* Marks the current content as saved (clears dirty). NULL is a no-op. */
void locus_text_buffer_mark_saved(LocusTextBuffer *buffer);

/*
 * Marks the current content as saved and releases undo/redo history. Intended
 * for a completed save when the live buffer still matches the saved snapshot.
 * NULL is a no-op.
 */
void locus_text_buffer_mark_saved_and_clear_history(LocusTextBuffer *buffer);

/**
 * Snapshots the text of lines [start_line, start_line + count) (clamped) as one
 * UTF-8 block, lines joined by '\n'.
 *
 * Ownership: on LOCUS_STATUS_OK, writes a Rust-owned snapshot to *out_snapshot;
 * release it with locus_text_snapshot_free. The snapshot's text pointer is
 * borrowed and is invalidated by that free.
 */
LocusStatus locus_text_buffer_snapshot_line_range(
    const LocusTextBuffer *buffer, size_t start_line, size_t count,
    LocusTextSnapshot **out_snapshot);

/**
 * Like locus_text_buffer_snapshot_line_range, but returns at most
 * max_bytes_per_line bytes of any single line's content (truncated on a UTF-8
 * character boundary). This keeps a file that is one enormous line from
 * materializing that whole line; a viewer passes a cap larger than it can show.
 *
 * Ownership: identical to locus_text_buffer_snapshot_line_range.
 */
LocusStatus locus_text_buffer_snapshot_line_range_capped(
    const LocusTextBuffer *buffer, size_t start_line, size_t count,
    size_t max_bytes_per_line, LocusTextSnapshot **out_snapshot);

/**
 * Snapshots the raw text of the UTF-16 range [start_utf16, end_utf16) with no
 * line-terminator stripping, for reading just the visible window of one enormous
 * line (intra-line virtualization). Both endpoints map to byte offsets in
 * O(log n). As a viewport read it never errors on the offsets: offsets past the
 * end are clamped, an endpoint inside a surrogate pair is floored to that
 * character's start (whole characters are returned), and an inverted range
 * yields empty text. The snapshot's line metadata is not meaningful for a raw
 * range and is reported as zero. Only a NULL out_snapshot/buffer is rejected.
 *
 * Ownership: identical to locus_text_buffer_snapshot_line_range.
 */
LocusStatus locus_text_buffer_snapshot_utf16_range(
    const LocusTextBuffer *buffer, size_t start_utf16, size_t end_utf16,
    LocusTextSnapshot **out_snapshot);

/*
 * Borrowed UTF-8 text of the snapshot, valid until locus_text_snapshot_free.
 * Length-counted (NOT NUL-terminated): always read locus_text_snapshot_byte_length
 * bytes, since an embedded NUL in the document is preserved.
 */
const char *locus_text_snapshot_text(const LocusTextSnapshot *snapshot);
size_t locus_text_snapshot_byte_length(const LocusTextSnapshot *snapshot);
size_t locus_text_snapshot_first_line(const LocusTextSnapshot *snapshot);
size_t locus_text_snapshot_line_count(const LocusTextSnapshot *snapshot);
void locus_text_snapshot_free(LocusTextSnapshot *snapshot);

/**
 * Maps a UTF-16 offset to a full position. The end-of-buffer offset is valid;
 * an offset inside a surrogate pair or past the end returns
 * LOCUS_TEXT_STATUS_INVALID_OFFSET. Writes *out_position on success.
 */
LocusStatus locus_text_buffer_position_for_utf16(
    const LocusTextBuffer *buffer, size_t utf16, LocusTextPosition *out_position);

/**
 * Maps a 0-based line and UTF-16 column (from the line start) to a full
 * position. A column past the line content is clamped to the line end; a line
 * past the last line returns LOCUS_TEXT_STATUS_INVALID_LINE.
 */
LocusStatus locus_text_buffer_position_for_line_column(
    const LocusTextBuffer *buffer, size_t line, size_t column_utf16,
    LocusTextPosition *out_position);

/*
 * Inserts text at a UTF-16 offset. The `_insert` form takes a NUL-terminated C
 * string (cannot carry an embedded NUL); `_insert_bytes` takes a length-counted
 * UTF-8 buffer that may contain NUL (invalid UTF-8 -> LOCUS_TEXT_STATUS_NOT_UTF8).
 */
LocusStatus locus_text_buffer_insert(
    LocusTextBuffer *buffer, size_t at_utf16, const char *text);
LocusStatus locus_text_buffer_insert_bytes(
    LocusTextBuffer *buffer, size_t at_utf16, const uint8_t *bytes, size_t len);

/* Deletes the UTF-16 range [start_utf16, end_utf16). */
LocusStatus locus_text_buffer_delete(
    LocusTextBuffer *buffer, size_t start_utf16, size_t end_utf16);

/*
 * Replaces the UTF-16 range [start_utf16, end_utf16) with a length-counted UTF-8
 * buffer (which may contain NUL) in a single undo step. Invalid UTF-8 ->
 * LOCUS_TEXT_STATUS_NOT_UTF8.
 */
LocusStatus locus_text_buffer_replace(
    LocusTextBuffer *buffer, size_t start_utf16, size_t end_utf16,
    const uint8_t *bytes, size_t len);

/*
 * Undo/redo (ABI version 5 signature). out_did_* (which may be NULL) receives
 * whether anything changed; out_change (which may be NULL) receives the span
 * the step rewrote, zeroed when nothing was undone/redone.
 */
LocusStatus locus_text_buffer_undo(
    LocusTextBuffer *buffer, bool *out_did_undo, LocusTextChange *out_change);
LocusStatus locus_text_buffer_redo(
    LocusTextBuffer *buffer, bool *out_did_redo, LocusTextChange *out_change);

/*
 * Writes the buffer's full content to the file at `path` (created/truncated),
 * streaming it so a multi-gigabyte document is not assembled in memory. The
 * caller owns any atomic-rename / symlink policy; this writes directly to `path`.
 */
LocusStatus locus_text_buffer_write_path(
    const LocusTextBuffer *buffer, const char *path);

/*
 * Save-snapshot API (ABI version 4): write the document on a background thread
 * while the user keeps editing. take_save_snapshot captures an immutable,
 * structurally-shared clone of the whole document (O(1), no content copy) and
 * seals the current insert run so the buffer can keep being edited without the
 * dirty flag drifting. snapshot_write_path streams that snapshot to disk and only
 * reads it, so unlike the mutating calls it may run concurrently with edits to
 * the originating buffer. After the write, mark_saved_snapshot records exactly the
 * snapshotted content as saved: a buffer edited during the write stays dirty, and
 * undoing back to the saved content reads clean again. The LocusTextBufferSnapshot
 * handle is distinct from LocusTextSnapshot (the borrowed viewport-read block) and
 * is released exactly once with locus_text_buffer_snapshot_free. Do not free a
 * snapshot until all background snapshot_write_path or snapshot-read calls using
 * it have returned.
 *
 * Ownership: on LOCUS_STATUS_OK, take_save_snapshot writes a Rust-owned snapshot to
 * *out_snapshot. take_save_snapshot and mark_saved_snapshot mutate the buffer and
 * need exclusive access to it; snapshot_write_path only reads the snapshot.
 * mark_saved_snapshot accepts only save snapshots taken from the same buffer;
 * passing a read-only snapshot or a save snapshot from another buffer returns
 * LOCUS_TEXT_STATUS_INVALID_ARGUMENT.
 */
LocusStatus locus_text_buffer_take_save_snapshot(
    LocusTextBuffer *buffer, LocusTextBufferSnapshot **out_snapshot);
LocusStatus locus_text_buffer_snapshot_write_path(
    const LocusTextBufferSnapshot *snapshot, const char *path);
LocusStatus locus_text_buffer_mark_saved_snapshot(
    LocusTextBuffer *buffer, const LocusTextBufferSnapshot *snapshot);
/* Passing NULL is allowed. Do not call while another thread is using snapshot. */
void locus_text_buffer_snapshot_free(LocusTextBufferSnapshot *snapshot);

/*
 * Snapshot read surface (added under ABI version 5): the same immutable
 * snapshot type also serves read-only background passes, e.g. measuring
 * soft-wrap row counts off the main thread while the user keeps editing.
 * take_snapshot is the non-mutating twin of take_save_snapshot: it does NOT
 * seal the insert-coalescing run (a measurement pass must not change undo
 * granularity) and never touches the dirty flag. The reads are safe from any
 * thread; read_line_range_capped mirrors
 * locus_text_buffer_snapshot_line_range_capped, and position_for_line_column
 * mirrors locus_text_buffer_position_for_line_column (column clamps to the
 * line's content end; an out-of-range line reports
 * LOCUS_TEXT_STATUS_INVALID_LINE). NULL snapshots report 0 from the scalar
 * reads.
 *
 * Ownership: on LOCUS_STATUS_OK, take_snapshot writes a Rust-owned snapshot to
 * *out_snapshot (released exactly once with locus_text_buffer_snapshot_free);
 * read_line_range_capped writes a Rust-owned text block to *out_snapshot
 * (released exactly once with locus_text_snapshot_free).
 */
LocusStatus locus_text_buffer_take_snapshot(
    const LocusTextBuffer *buffer, LocusTextBufferSnapshot **out_snapshot);
size_t locus_text_buffer_snapshot_line_count(
    const LocusTextBufferSnapshot *snapshot);
size_t locus_text_buffer_snapshot_utf16_length(
    const LocusTextBufferSnapshot *snapshot);
LocusStatus locus_text_buffer_snapshot_read_line_range_capped(
    const LocusTextBufferSnapshot *snapshot, size_t start_line, size_t count,
    size_t max_bytes_per_line, LocusTextSnapshot **out_snapshot);
LocusStatus locus_text_buffer_snapshot_position_for_line_column(
    const LocusTextBufferSnapshot *snapshot, size_t line, size_t column_utf16,
    LocusTextPosition *out_position);

/*
 * Read-only, line-indexed large-file viewer (see app_core::line_index).
 *
 * For a file too large to load into an editable buffer: it is scanned once to
 * build a sparse line index, then line ranges are served by reading only the
 * needed window via positioned reads. An external truncation surfaces as a short
 * read, never a fault, so a concurrent rewrite never crashes the process.
 */
typedef struct LocusLargeFile LocusLargeFile;

/*
 * Opens `path` as a read-only line-indexed large file.
 *
 * Ownership: on LOCUS_STATUS_OK, writes a Rust-owned handle to *out_file that the
 * caller releases exactly once with locus_large_file_free.
 */
LocusStatus locus_large_file_open(const char *path, LocusLargeFile **out_file);

/* Releases a large-file handle. Passing NULL is allowed and has no effect. */
void locus_large_file_free(LocusLargeFile *file);

/* Scalar queries. NULL returns 0. */
size_t locus_large_file_line_count(const LocusLargeFile *file);
uint64_t locus_large_file_byte_length(const LocusLargeFile *file);
/* Total UTF-16 code units (size_t, mirroring locus_text_buffer_utf16_length). */
size_t locus_large_file_utf16_length(const LocusLargeFile *file);

/*
 * Snapshots the text of lines [start_line, start_line + count) (clamped) by
 * reading only that window from the file, lines joined by '\n'.
 *
 * Ownership: on LOCUS_STATUS_OK, writes a Rust-owned snapshot to *out_snapshot;
 * release it with locus_text_snapshot_free (the shared snapshot type). Its text
 * pointer is borrowed and invalidated by that free.
 */
LocusStatus locus_large_file_snapshot_line_range(
    const LocusLargeFile *file, size_t start_line, size_t count,
    LocusTextSnapshot **out_snapshot);

/*
 * Like locus_large_file_snapshot_line_range, but returns at most
 * max_bytes_per_line bytes of any single line's content (truncated on a UTF-8
 * character boundary), so a file that is one enormous line is not materialized
 * to paint a band. Ownership matches locus_large_file_snapshot_line_range.
 */
LocusStatus locus_large_file_snapshot_line_range_capped(
    const LocusLargeFile *file, size_t start_line, size_t count,
    size_t max_bytes_per_line, LocusTextSnapshot **out_snapshot);

/*
 * Snapshots the raw text of the UTF-16 range [start_utf16, end_utf16) with no
 * line-terminator stripping, for copying a selection within or across lines. The
 * endpoints are mapped by scanning forward from the nearest line checkpoint (the
 * index is checkpointed by line, not by byte), so a within-line seek is linear in
 * the enclosing line's length; the platform refuses a file with a pathologically
 * long single line, keeping that bound small. As a viewport read it clamps rather
 * than erroring: offsets past the end are clamped, an endpoint inside a surrogate
 * pair is floored to that character's start, and an inverted range yields empty
 * text. The snapshot's line metadata is not meaningful here and is reported as
 * zero. Only a NULL out_snapshot/file is rejected. Ownership matches
 * locus_large_file_snapshot_line_range.
 */
LocusStatus locus_large_file_snapshot_utf16_range(
    const LocusLargeFile *file, size_t start_utf16, size_t end_utf16,
    LocusTextSnapshot **out_snapshot);

/*
 * Maps a UTF-16 offset to a full position (writes *out_position on success,
 * reusing the LocusTextPosition layout above). Unlike
 * locus_text_buffer_position_for_utf16, this is a viewport read that never
 * rejects the offset: an offset past the end is clamped to the end and an offset
 * inside a surrogate pair is floored to that character's start. Only a NULL
 * handle/out_position or an underlying read error (LOCUS_TEXT_STATUS_IO) is
 * reported.
 */
LocusStatus locus_large_file_position_for_utf16(
    const LocusLargeFile *file, size_t utf16, LocusTextPosition *out_position);

/*
 * Maps a 0-based line and UTF-16 column (from the line start) to a full
 * position. Also clamp-safe: a column past the line content is clamped to the
 * line end, a column inside a surrogate pair is floored to that character's
 * start, and a line past the last line is clamped to the last line (never
 * rejected, unlike locus_text_buffer_position_for_line_column). Only a NULL
 * handle/out_position or an underlying read error is reported.
 */
LocusStatus locus_large_file_position_for_line_column(
    const LocusLargeFile *file, size_t line, size_t column_utf16,
    LocusTextPosition *out_position);

/*
 * Terminal emulator preview ABI (added under ABI version 6).
 *
 * The terminal handle contains parser state only; it does not spawn or own a
 * PTY. Feed bytes from a platform-owned process, render into a reusable frame,
 * and release all Rust-owned byte/frame handles with the matching free calls.
 *
 * Thread-safety: terminal handles and frames are not thread-safe. Callers may
 * use them from any thread, but each individual handle must be serialized by
 * the caller and never used concurrently.
 *
 * Panic policy: if a terminal entry point returns LOCUS_TERM_STATUS_PANIC, the
 * handle state is undefined. Free the handle and create a new one.
 */

#define LOCUS_TERM_ABI_VERSION ((uint32_t)4u)

#define LOCUS_TERM_STATUS_INVALID_ARGUMENT ((LocusStatus)300u)
#define LOCUS_TERM_STATUS_PANIC ((LocusStatus)301u)
#define LOCUS_TERM_STATUS_UNSAFE_PASTE ((LocusStatus)302u)

#define LOCUS_TERM_SEARCH_SELECT_NEXT ((uint32_t)0u) /* toward older */
#define LOCUS_TERM_SEARCH_SELECT_PREV ((uint32_t)1u) /* toward newer */
#define LOCUS_TERM_SEARCH_NO_SELECTION UINT32_MAX
#define LOCUS_TERM_SEARCH_MATCH_SELECTED ((uint16_t)(1u << 0))
#define LOCUS_TERM_SEARCH_MAX_NEEDLE_BYTES ((size_t)1024u)

/* Terminal resource limits; must match app-ffi. */
#define LOCUS_TERM_MAX_COLS ((uint16_t)4096u)
#define LOCUS_TERM_MAX_ROWS ((uint16_t)4096u)
#define LOCUS_TERM_MAX_SCROLLBACK ((size_t)(256u * 1024u * 1024u))

#define LOCUS_TERM_DIRTY_NONE ((uint32_t)0u)
#define LOCUS_TERM_DIRTY_PARTIAL ((uint32_t)1u)
#define LOCUS_TERM_DIRTY_FULL ((uint32_t)2u)

#define LOCUS_TERM_ACTION_RELEASE ((uint32_t)0u)
#define LOCUS_TERM_ACTION_PRESS ((uint32_t)1u)
#define LOCUS_TERM_ACTION_REPEAT ((uint32_t)2u)

#define LOCUS_TERM_SELECTION_PRESS ((uint32_t)0u)
#define LOCUS_TERM_SELECTION_DRAG ((uint32_t)1u)
#define LOCUS_TERM_SELECTION_RELEASE ((uint32_t)2u)
#define LOCUS_TERM_SELECTION_PRESS_REPEAT ((uint32_t)3u)

#define LOCUS_TERM_MOUSE_PRESS ((uint32_t)0u)
#define LOCUS_TERM_MOUSE_RELEASE ((uint32_t)1u)
#define LOCUS_TERM_MOUSE_MOTION ((uint32_t)2u)
#define LOCUS_TERM_MOUSE_BUTTON_LEFT ((uint32_t)0u)
#define LOCUS_TERM_MOUSE_BUTTON_MIDDLE ((uint32_t)1u)
#define LOCUS_TERM_MOUSE_BUTTON_RIGHT ((uint32_t)2u)
#define LOCUS_TERM_MOUSE_BUTTON_WHEEL_UP ((uint32_t)3u)
#define LOCUS_TERM_MOUSE_BUTTON_WHEEL_DOWN ((uint32_t)4u)
#define LOCUS_TERM_MOUSE_BUTTON_WHEEL_LEFT ((uint32_t)5u)
#define LOCUS_TERM_MOUSE_BUTTON_WHEEL_RIGHT ((uint32_t)6u)
#define LOCUS_TERM_MOUSE_BUTTON_NONE UINT32_MAX

#define LOCUS_TERM_MOD_SHIFT ((uint16_t)(1u << 0))
#define LOCUS_TERM_MOD_CTRL ((uint16_t)(1u << 1))
#define LOCUS_TERM_MOD_ALT ((uint16_t)(1u << 2))
#define LOCUS_TERM_MOD_SUPER ((uint16_t)(1u << 3))
#define LOCUS_TERM_MOD_CAPS_LOCK ((uint16_t)(1u << 4))
#define LOCUS_TERM_MOD_NUM_LOCK ((uint16_t)(1u << 5))

#define LOCUS_TERM_KEY_UNIDENTIFIED ((uint32_t)0u)
#define LOCUS_TERM_KEY_ENTER ((uint32_t)1u)
#define LOCUS_TERM_KEY_BACKSPACE ((uint32_t)2u)
#define LOCUS_TERM_KEY_TAB ((uint32_t)3u)
#define LOCUS_TERM_KEY_ESCAPE ((uint32_t)4u)
#define LOCUS_TERM_KEY_ARROW_UP ((uint32_t)10u)
#define LOCUS_TERM_KEY_ARROW_DOWN ((uint32_t)11u)
#define LOCUS_TERM_KEY_ARROW_LEFT ((uint32_t)12u)
#define LOCUS_TERM_KEY_ARROW_RIGHT ((uint32_t)13u)
#define LOCUS_TERM_KEY_HOME ((uint32_t)14u)
#define LOCUS_TERM_KEY_END ((uint32_t)15u)
#define LOCUS_TERM_KEY_PAGE_UP ((uint32_t)16u)
#define LOCUS_TERM_KEY_PAGE_DOWN ((uint32_t)17u)
#define LOCUS_TERM_KEY_DELETE ((uint32_t)18u)
#define LOCUS_TERM_KEY_INSERT ((uint32_t)19u)
#define LOCUS_TERM_KEY_F1 ((uint32_t)101u)
#define LOCUS_TERM_KEY_F2 ((uint32_t)102u)
#define LOCUS_TERM_KEY_F3 ((uint32_t)103u)
#define LOCUS_TERM_KEY_F4 ((uint32_t)104u)
#define LOCUS_TERM_KEY_F5 ((uint32_t)105u)
#define LOCUS_TERM_KEY_F6 ((uint32_t)106u)
#define LOCUS_TERM_KEY_F7 ((uint32_t)107u)
#define LOCUS_TERM_KEY_F8 ((uint32_t)108u)
#define LOCUS_TERM_KEY_F9 ((uint32_t)109u)
#define LOCUS_TERM_KEY_F10 ((uint32_t)110u)
#define LOCUS_TERM_KEY_F11 ((uint32_t)111u)
#define LOCUS_TERM_KEY_F12 ((uint32_t)112u)
#define LOCUS_TERM_KEY_F13 ((uint32_t)113u)
#define LOCUS_TERM_KEY_F14 ((uint32_t)114u)
#define LOCUS_TERM_KEY_F15 ((uint32_t)115u)
#define LOCUS_TERM_KEY_F16 ((uint32_t)116u)
#define LOCUS_TERM_KEY_F17 ((uint32_t)117u)
#define LOCUS_TERM_KEY_F18 ((uint32_t)118u)
#define LOCUS_TERM_KEY_F19 ((uint32_t)119u)
#define LOCUS_TERM_KEY_F20 ((uint32_t)120u)

typedef struct LocusTerm LocusTerm;
typedef struct LocusTermFrameStorage LocusTermFrameStorage;

typedef struct LocusTermBytes {
    uint8_t *ptr;
    size_t len;
    size_t cap;
} LocusTermBytes;

typedef struct LocusTermRgb {
    uint8_t r;
    uint8_t g;
    uint8_t b;
} LocusTermRgb;

typedef struct LocusTermCursor {
    uint16_t x;
    uint16_t y;
    bool visible;
    bool blinking;
    bool wide_tail;
    uint32_t style;
} LocusTermCursor;

typedef struct LocusTermCell {
    uint32_t codepoint;
    uint64_t raw;
    LocusTermRgb fg;
    LocusTermRgb bg;
    uint32_t flags;
    uint8_t wide;
    size_t grapheme_start;
    size_t grapheme_len;
    uint16_t hyperlink_id;
} LocusTermCell;

typedef struct LocusTermRow {
    uint16_t y;
    size_t cell_start;
    size_t cell_count;
    bool dirty;
    bool wrapped;
    /* Inclusive selected columns; UINT16_MAX in both fields means none. */
    uint16_t sel_start;
    uint16_t sel_end;
} LocusTermRow;

typedef struct LocusTermFrame {
    uint32_t abi_version;
    uint16_t cols;
    uint16_t rows;
    uint32_t dirty_state;
    int32_t scroll_delta;
    uint32_t viewport_offset_rows;
    uint32_t total_rows;
    bool at_bottom;
    size_t row_count;
    const LocusTermRow *rows_ptr;
    size_t cell_count;
    const LocusTermCell *cells_ptr;
    size_t grapheme_count;
    const uint32_t *graphemes_ptr;
    LocusTermCursor cursor;
    /* Private Rust-owned storage. Callers must not read, write, or free it. */
    LocusTermFrameStorage *storage;
} LocusTermFrame;

typedef struct LocusTermKeyEvent {
    uint32_t action;
    uint32_t key;
    uint16_t mods;
    uint16_t consumed_mods;
    bool composing;
    const uint8_t *utf8;
    size_t utf8_len;
    uint32_t unshifted_codepoint;
} LocusTermKeyEvent;

typedef struct LocusTermSearchStatus {
    bool active;
    bool complete;
    uint32_t total;
    /* Index from newest, or LOCUS_TERM_SEARCH_NO_SELECTION. */
    uint32_t selected;
} LocusTermSearchStatus;

typedef struct LocusTermSearchMatch {
    uint16_t y;
    uint16_t x_start;
    uint16_t x_end;
    /* Bit 0 means this row belongs to the selected match. */
    uint16_t flags;
} LocusTermSearchMatch;

typedef struct LocusTermLinkMatch {
    uint16_t y;
    uint16_t x_start;
    uint16_t x_end;
    uint16_t link_id;
} LocusTermLinkMatch;

uint32_t locus_term_abi_version(void);
LocusTerm *locus_term_new(uint16_t cols, uint16_t rows, size_t max_scrollback);
void locus_term_free(LocusTerm *term);

LocusStatus locus_term_feed(LocusTerm *term, const uint8_t *bytes, size_t len);
LocusStatus locus_term_take_responses(LocusTerm *term, LocusTermBytes *out);
/*
 * Copies and clears the latest honored OSC 52 clipboard write. Clipboard read
 * requests are never honored. Free the result with locus_term_bytes_free.
 */
LocusStatus locus_term_take_clipboard_write(
    LocusTerm *term, LocusTermBytes *out);
void locus_term_bytes_free(LocusTermBytes *bytes);
LocusStatus locus_term_resize(LocusTerm *term, uint16_t cols, uint16_t rows);
LocusStatus locus_term_render(
    LocusTerm *term, LocusTermFrame *frame, bool full);
LocusTermFrame *locus_term_frame_new(void);
void locus_term_frame_free(LocusTermFrame *frame);
LocusStatus locus_term_key(
    LocusTerm *term, const LocusTermKeyEvent *event, LocusTermBytes *out);
LocusStatus locus_term_search_start(
    LocusTerm *term, const uint8_t *needle, size_t len);
LocusStatus locus_term_search_end(LocusTerm *term);
LocusStatus locus_term_search_status(
    LocusTerm *term, LocusTermSearchStatus *out);
LocusStatus locus_term_search_select(
    LocusTerm *term, uint32_t direction, LocusTermSearchStatus *out);
/*
 * Packed LocusTermSearchMatch records sorted by (y, x_start). The result is
 * capped at rows * 64 records and must be freed with locus_term_bytes_free.
 */
LocusStatus locus_term_search_viewport_matches(
    LocusTerm *term, LocusTermBytes *out);
/*
 * Packed LocusTermLinkMatch records sorted by (y, x_start), capped at
 * rows * 64 records and freed with locus_term_bytes_free. Link IDs remain
 * valid until the next locus_term_viewport_links call.
 */
LocusStatus locus_term_viewport_links(
    LocusTerm *term, LocusTermBytes *out);
/*
 * UTF-8 URI for a link ID from the last viewport-links call. Unknown or stale
 * IDs return an empty byte buffer.
 */
LocusStatus locus_term_link_uri(
    LocusTerm *term, uint32_t link_id, LocusTermBytes *out);
/* Bit 0 = modifyOtherKeys state 2; bit 1 = active kitty keyboard flags. */
uint32_t locus_term_key_protocol_active(const LocusTerm *term);
/*
 * Returns LOCUS_TERM_STATUS_UNSAFE_PASTE only when bracketed paste is off,
 * the input contains unsafe newline or control data, and allow_unsafe is
 * false. After explicit user confirmation, callers may retry with
 * allow_unsafe=true.
 */
LocusStatus locus_term_paste(
    LocusTerm *term, const uint8_t *bytes, size_t len, bool allow_unsafe,
    LocusTermBytes *out);
LocusStatus locus_term_scroll(LocusTerm *term, intptr_t delta);
/* Coordinates are viewport cells; cell_fraction_x refines the horizontal edge. */
LocusStatus locus_term_selection_gesture(
    LocusTerm *term, uint32_t kind, uint16_t x, uint16_t y,
    float cell_fraction_x, bool rectangle);
LocusStatus locus_term_selection_clear(LocusTerm *term);
LocusStatus locus_term_selection_string(
    LocusTerm *term, LocusTermBytes *out);
/* Copies the most recent window title; empty when unset. */
LocusStatus locus_term_latest_title(
    LocusTerm *term, LocusTermBytes *out);
/* Copies the most recent OSC 7 working-directory report verbatim. */
LocusStatus locus_term_latest_pwd(
    LocusTerm *term, LocusTermBytes *out);
LocusStatus locus_term_autoscroll_tick(
    LocusTerm *term, int32_t direction, uint16_t x, float cell_fraction_x,
    bool rectangle);
/* Empty output means the caller should handle the mouse event locally. */
LocusStatus locus_term_mouse(
    LocusTerm *term, uint32_t kind, uint32_t button, uint16_t x, uint16_t y,
    uint16_t mods, LocusTermBytes *out);
/* Routes wheel input to mouse reports, alternate-scroll keys, or scrollback. */
LocusStatus locus_term_scroll_wheel(
    LocusTerm *term, int32_t delta_rows, uint16_t x, uint16_t y,
    uint16_t mods, LocusTermBytes *out);

/*
 * PTY process management ABI (added under ABI version 6).
 *
 * The PTY handle owns the child process and master file descriptor. Callers may
 * watch locus_pty_master_fd() with a platform event source and drive reads when
 * readable. String inputs are UTF-8 byte slices; embedded NUL bytes are
 * rejected before spawning.
 *
 * Thread-safety: PTY handles are not thread-safe. Callers may use a handle from
 * any thread, but each individual handle must be serialized by the caller and
 * never used concurrently.
 *
 * Panic policy: if a PTY entry point returns LOCUS_PTY_STATUS_PANIC, the handle
 * state is undefined. Free the handle and create a new one.
 */

#define LOCUS_PTY_STATUS_INVALID_ARGUMENT ((LocusStatus)400u)
#define LOCUS_PTY_STATUS_IO ((LocusStatus)401u)
#define LOCUS_PTY_STATUS_WOULD_BLOCK ((LocusStatus)402u)
#define LOCUS_PTY_STATUS_CHILD_EXEC ((LocusStatus)403u)
#define LOCUS_PTY_STATUS_TIMEOUT ((LocusStatus)404u)
#define LOCUS_PTY_STATUS_PANIC ((LocusStatus)405u)

typedef struct LocusPty LocusPty;

typedef struct LocusPtyString {
    const uint8_t *ptr;
    size_t len;
} LocusPtyString;

typedef struct LocusPtyEnvVar {
    LocusPtyString key;
    LocusPtyString value;
} LocusPtyEnvVar;

typedef struct LocusPtyOptions {
    uint16_t cols;
    uint16_t rows;
    /*
     * Empty command means the user's login shell from passwd, falling back to
     * /bin/zsh. Non-empty command is executed directly; no shell wrapper is
     * inserted.
     */
    LocusPtyString command;
    const LocusPtyString *args;
    size_t args_len;
    /* Empty cwd means inherit the app process cwd. Non-empty cwd must exist. */
    LocusPtyString cwd;
    const LocusPtyEnvVar *env;
    size_t env_len;
} LocusPtyOptions;

typedef struct LocusPtyExitStatus {
    bool exited;
    int32_t code;   /* -1 when not exited by status code. */
    int32_t signal; /* 0 when not exited by signal. */
} LocusPtyExitStatus;

LocusPty *locus_pty_spawn(const LocusPtyOptions *options);
int32_t locus_pty_master_fd(const LocusPty *pty);
LocusStatus locus_pty_read(
    LocusPty *pty, uint8_t *buf, size_t cap, size_t *out_len);
LocusStatus locus_pty_write(
    LocusPty *pty, const uint8_t *bytes, size_t len, size_t *out_len);
LocusStatus locus_pty_resize(LocusPty *pty, uint16_t cols, uint16_t rows);
LocusStatus locus_pty_try_wait(
    LocusPty *pty, LocusPtyExitStatus *out_status);
/*
 * Sends SIGHUP, waits briefly, then escalates to SIGKILL if the child is still
 * alive. Drop/free also closes the master, sends SIGHUP, and escalates to
 * SIGKILL after a short non-blocking reap window.
 */
LocusStatus locus_pty_shutdown(LocusPty *pty);
void locus_pty_free(LocusPty *pty);

#ifdef __cplusplus
}
#endif

#endif
