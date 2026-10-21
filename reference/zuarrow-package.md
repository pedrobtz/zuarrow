# zuarrow: Exact Conversion Between R Vectors and 'Apache Arrow' Columns

Moves columns between R and the 'Apache Arrow' columnar format: the C
data interface in memory and the inter-process communication ('IPC')
stream and file formats on disk. Every 'Arrow' type converts to an R
vector and back, and a conversion either keeps every value unchanged or
raises an error that names the column and the R type that would hold it
exactly. A registry lets other packages declare which R class is the
exact form of which 'Arrow' type. Handles share the layout of the
'nanoarrow' package, so objects pass between the two without conversion.
The format is specified at
<https://arrow.apache.org/docs/format/Columnar.html>.

## See also

Useful links:

- <https://github.com/pedrobtz/zuarrow>

- <https://pedrobtz.github.io/zuarrow/>

- Report bugs at <https://github.com/pedrobtz/zuarrow/issues>

## Author

**Maintainer**: Pedro Baltazar <pedrobtz@gmail.com> \[copyright holder\]

Authors:

- Pedro Baltazar <pedrobtz@gmail.com> \[copyright holder\]
