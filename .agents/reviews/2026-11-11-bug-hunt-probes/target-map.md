# Target map — zuarrow at ff3dcba

Boundaries (from .agents/assurance.md): IPC stream and file decoding (raw, file path, connection, list of sources, lazy and eager); LZ4_FRAME/ZSTD bodies, both directions; dictionary and delta-dictionary batches; big-endian refused; IPC encoding of every type, both framings, every codec; Arrow->R conversion (every type, offsets, several batches, nested, dictionary->factor, REE, unions, views); R->Arrow conversion (inference and explicit schemas); C Data Interface import/export; strict UTF-8 validation; metadata; arrow_equal / arrow_validate.

Limits: arrow_limits(max_bytes, max_message, max_batch_rows, max_depth, max_dictionary); conversion depth 64; compressed length prefix; zuarrow.utf8_limit and 2^31-1 offsets; list->large_list; int64/uint64 2^53; integer widths on export; ZAR_MAX_PREBUILT 256; ZAR_DIRECT_MAX 16; connection block 1 MiB; batch= argument of arrow_write/arrow_stream.

Long-lived objects: schema, array and stream handles (zuarrow_* external pointers, nanoarrow r.h layout); arrow_stream() over arrays and borrowed arrays; IPC reader stream (lazy = TRUE); chain of readers; ALTREP deferred strings (copy = FALSE); registry state.

Numbers into C: batch, schema-driven widths, arrow_limits values, arrow_next(), arrow_validate(level), handler outputs, row counts.

Weakest (gaps): alloc failure #182, fuzz oracle #185, write of non-flat types vs libarrow #186, UTF-8 differential #187, reader/chain state transitions #188, stream batches after move #189, every arrow_limits straddle #190, 2^31 limits #191, connection block / direct path #192, registry multi-batch #198, deferred strings handle reuse #181.

Platform branches: _WIN32 in zar_ipc_read.c (unverified here, macOS only); ZAR_STANDALONE (built: replay-reader).
