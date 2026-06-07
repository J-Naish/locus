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
 * (line count, byte/UTF-16 length, revision, is-dirty, the position queries, and
 * the line-range and UTF-16-range snapshots) plus locus_text_buffer_write_path,
 * which only reads the buffer to stream it out. The mutating calls --
 * locus_text_buffer_insert_bytes, locus_text_buffer_delete,
 * locus_text_buffer_replace, locus_text_buffer_undo, locus_text_buffer_redo, and
 * locus_text_buffer_mark_saved -- plus locus_text_buffer_free require exclusive
 * access: the caller must ensure no other call on the same handle (read or
 * write) overlaps them. Overlapping a mutation with any other access is
 * undefined behavior. This is what lets a background save read the buffer while
 * the UI thread keeps rendering, as long as edits are paused for the save.
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
 * Opaque Rust-owned handles. Callers must never allocate, free, copy, or
 * inspect these directly; use the functions below.
 */
typedef struct LocusTextBuffer LocusTextBuffer;
typedef struct LocusTextSnapshot LocusTextSnapshot;

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

/* Marks the current content as saved (clears dirty). NULL is a no-op. */
void locus_text_buffer_mark_saved(LocusTextBuffer *buffer);

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

/* Undo/redo. out_did_* (which may be NULL) receives whether anything changed. */
LocusStatus locus_text_buffer_undo(LocusTextBuffer *buffer, bool *out_did_undo);
LocusStatus locus_text_buffer_redo(LocusTextBuffer *buffer, bool *out_did_redo);

/*
 * Writes the buffer's full content to the file at `path` (created/truncated),
 * streaming it so a multi-gigabyte document is not assembled in memory. The
 * caller owns any atomic-rename / symlink policy; this writes directly to `path`.
 */
LocusStatus locus_text_buffer_write_path(
    const LocusTextBuffer *buffer, const char *path);

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
uint64_t locus_large_file_max_line_byte_length(const LocusLargeFile *file);

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

#ifdef __cplusplus
}
#endif

#endif
