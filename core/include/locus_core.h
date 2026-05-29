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

#ifdef __cplusplus
}
#endif

#endif
