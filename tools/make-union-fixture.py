#!/usr/bin/env python3
# Writes tests/testthat/data/geometry-union.arrows: an IPC stream of two
# record batches whose column `geom` is a dense_union shaped like GeoArrow's
# `geoarrow.geometry` extension (GeoArrow 0.2 format.md). Type ids are the
# geometry type codes: 1 to 7 for XY, 11 to 17 for Z, 21 to 27 for M and 31
# to 37 for ZM. The union holds a subset of children, as the format allows:
#
#   1  Point       struct<x, y>
#   2  LineString  list<vertices: struct<x, y>>
#   11 Point Z     struct<x, y, z>
#
# zuarrow has no R form for unions; test-registry.R reads this column
# through a test-only registration of `geoarrow.geometry` (#171).
# geoarrow-data v0.2.0 has no union-encoded file, so the fixture is
# generated here and committed.
#
# The committed file is pyarrow 26.0.1's output (2026-11-06). Run from the
# package root, in a virtual environment with pyarrow installed:
#
#   python3 -m venv /tmp/venv && /tmp/venv/bin/pip install pyarrow
#   /tmp/venv/bin/python tools/make-union-fixture.py
#
# Update the version here when regenerating it.
import pyarrow as pa
import pyarrow.ipc

print("writing with pyarrow", pa.__version__)

xy = pa.struct([pa.field("x", pa.float64(), False), pa.field("y", pa.float64(), False)])
xyz = pa.struct(
    [
        pa.field("x", pa.float64(), False),
        pa.field("y", pa.float64(), False),
        pa.field("z", pa.float64(), False),
    ]
)
children = [
    pa.field("Point", xy),
    pa.field("LineString", pa.list_(pa.field("vertices", xy, False))),
    pa.field("Point Z", xyz),
]
type_codes = [1, 2, 11]
union = pa.dense_union(children, type_codes)


class GeometryType(pa.ExtensionType):
    def __init__(self):
        super().__init__(union, "geoarrow.geometry")

    def __arrow_ext_serialize__(self):
        return b"{}"

    @classmethod
    def __arrow_ext_deserialize__(cls, storage_type, serialized):
        return cls()


geometry = GeometryType()


def batch(ids, type_ids, offsets, points, lines, points_z):
    storage = pa.UnionArray.from_dense(
        pa.array(type_ids, pa.int8()),
        pa.array(offsets, pa.int32()),
        [
            pa.array(points, xy),
            pa.array(lines, children[1].type),
            pa.array(points_z, xyz),
        ],
        [c.name for c in children],
        type_codes,
    )
    return pa.record_batch(
        [pa.array(ids, pa.int32()), pa.ExtensionArray.from_storage(geometry, storage)],
        names=["id", "geom"],
    )


first = batch(
    [1, 2, 3, 4],
    [1, 2, 11, 1],
    [0, 0, 0, 1],
    [{"x": 1.0, "y": 2.0}, {"x": 5.0, "y": 6.0}],
    [[{"x": 0.0, "y": 0.0}, {"x": 1.0, "y": 1.0}]],
    [{"x": 3.0, "y": 4.0, "z": 5.0}],
)
second = batch(
    [5, 6],
    [11, 2],
    [0, 0],
    [],
    [[{"x": 2.0, "y": 3.0}, {"x": 4.0, "y": 5.0}, {"x": 6.0, "y": 7.0}]],
    [{"x": -1.0, "y": -2.0, "z": -3.0}],
)

with pa.OSFile("tests/testthat/data/geometry-union.arrows", "wb") as sink:
    with pa.ipc.new_stream(sink, first.schema) as writer:
        writer.write_batch(first)
        writer.write_batch(second)
