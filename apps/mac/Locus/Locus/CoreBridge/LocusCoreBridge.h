#ifndef LOCUS_CORE_BRIDGE_H
#define LOCUS_CORE_BRIDGE_H

/*
 * Keep Swift's visible C surface routed through this app-owned bridging header.
 * It gives the macOS shell one place to add Swift-facing annotations or narrow
 * imported FFI declarations without changing the shared Rust header.
 */
#include "locus_core.h"

#endif
