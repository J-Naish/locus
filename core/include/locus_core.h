#ifndef LOCUS_CORE_H
#define LOCUS_CORE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

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
 * Compatibility policy for ABI version 1 is exact match. Callers should treat a
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

#ifdef __cplusplus
}
#endif

#endif
