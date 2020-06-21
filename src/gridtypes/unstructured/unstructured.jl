const Connectivity{T} =
    Union{AbstractVector{T}, NTuple{N,T} where N} where {T <: Integer}

"""
    MeshCell

Single cell element in unstructured or polygonal grid.

It is characterised by a cell type (for instance, `VTKCellType.TRIANGLE` or
`PolyData.Strips`) and by a connectivity vector determining the points on the
grid defining this cell.

---

    MeshCell(cell_type, connectivity::AbstractVector)

Define a single cell element of an unstructured grid.

The `cell_type` argument characterises the type of cell (e.g. vertex, triangle,
hexaedron, ...):

- cell types for unstructured datasets are defined in the [`VTKCellTypes`](@ref)
module;
- cell types for polygonal datasets are defined in the [`PolyData`](@ref) module.

The `connectivity` argument is a vector containing the indices of the points
passed to [`vtk_grid`](@ref) which define this cell.

# Example

Define a triangular cell passing by points with indices `[3, 5, 42]`.

```julia
cell = MeshCell(VTKCellTypes.VTK_TRIANGLE, [3, 5, 42])
```
"""
struct MeshCell{CellType, V <: Connectivity}
    ctype::CellType  # cell type identifier (see VTKCellTypes.jl)
    connectivity::V  # indices of points (one-based, following the convention in Julia)
    function MeshCell(ctype, conn)
        if nodes(ctype) ∉ (length(conn), -1)
            error("Wrong number of nodes in connectivity vector.")
        end
        C = typeof(ctype)
        V = typeof(conn)
        new{C,V}(ctype, conn)
    end
end

Base.eltype(::Type{<:MeshCell}) = VTKCellTypes.VTKCellType
cell_type(cell::MeshCell) = cell.ctype

# By default, MeshCell are attached to unstructured grids.
grid_type(::Type{<:MeshCell}) = VTKUnstructuredGrid()

function add_cells!(vtk, xml_piece, number_attr, xml_name, cells;
                    with_types::Val=Val(true))
    Cell = eltype(cells)
    Ncls = length(cells)
    write_types = with_types === Val(true)

    # Create data arrays.
    offsets = Array{Int32}(undef, Ncls)

    # Write `types` array? This must be true for unstructured grids,
    # and false for polydata.
    if write_types
        types = Array{UInt8}(undef, Ncls)
    end

    Nconn = 0     # length of the connectivity array
    if Ncls >= 1  # it IS possible to have no cells
        offsets[1] = length(cells[1].connectivity)
    end

    for (n, c) in enumerate(cells)
        Npts_cell = length(c.connectivity)
        Nconn += Npts_cell
        if write_types
            types[n] = cell_type(c).vtk_id
        end
        if n >= 2
            offsets[n] = offsets[n-1] + Npts_cell
        end
    end

    # Create connectivity array.
    conn = Array{Int32}(undef, Nconn)
    n = 1
    for c in cells, i in c.connectivity
        # We transform to zero-based indexing, required by VTK.
        conn[n] = i - 1
        n += 1
    end

    # Add arrays to the XML file (DataArray nodes).
    set_attribute(xml_piece, number_attr, Ncls)

    xnode = new_child(xml_piece, xml_name)
    data_to_xml(vtk, xnode, conn, "connectivity")
    data_to_xml(vtk, xnode, offsets, "offsets")
    if write_types
        data_to_xml(vtk, xnode, types, "types")
    end

    vtk
end

const CellVector = AbstractVector{<:MeshCell}

function vtk_grid(dtype::VTKUnstructuredGrid, filename::AbstractString,
                  points::AbstractArray, cells::CellVector;
                  kwargs...)
    @assert size(points, 1) == 3
    Npts = prod(size(points)[2:end])
    Ncls = length(cells)

    xvtk = XMLDocument()
    vtk = DatasetFile(dtype, xvtk, filename, Npts, Ncls; kwargs...)

    xroot = vtk_xml_write_header(vtk)
    xGrid = new_child(xroot, vtk.grid_type)

    xPiece = new_child(xGrid, "Piece")
    set_attribute(xPiece, "NumberOfPoints", vtk.Npts)

    xPoints = new_child(xPiece, "Points")
    data_to_xml(vtk, xPoints, points, "Points", 3)

    add_cells!(vtk, xPiece, "NumberOfCells", "Cells", cells)

    vtk
end

# Variant of vtk_grid with 2-D array "points".
#   size(points) = (dim, num_points), with dim ∈ {1, 2, 3}
function vtk_grid(filename::AbstractString, points::AbstractArray{T,2},
                  cells::CellVector, args...; kwargs...) where T
    dim, Npts = size(points)
    gtype = grid_type(eltype(cells))
    if dim == 3
        return vtk_grid(gtype, filename, points, cells, args...; kwargs...)
    end
    # Reshape to 3D
    _points = zeros(T, 3, Npts)
    if isdefined(Base, :require_one_based_indexing)  # not the case in Julia 1.0
        Base.require_one_based_indexing(points)
    end
    if dim ∉ (1, 2)
        msg = string("`points` array must be of size (dim, Npts), ",
                     "where dim = 1, 2 or 3 and `Npts` the number of points.\n",
                     "Actual size of input: $(size(points))")
        throw(DimensionMismatch(msg))
    end
    for I in CartesianIndices(points)
        _points[I] = points[I]
    end
    vtk_grid(gtype, filename, _points, cells, args...; kwargs...)
end

# Variant of vtk_grid with 1-D arrays x, y, z.
# Size of each array: (num_points)
function vtk_grid(filename::AbstractString, x::AbstractVector{T},
                  y::AbstractVector{T}, z::AbstractVector{T},
                  cells::CellVector, args...; kwargs...) where {T}
    if !(length(x) == length(y) == length(z))
        throw(DimensionMismatch("length of x, y and z arrays must be the same."))
    end
    Npts = length(x)
    points = Array{T}(undef, 3, Npts)
    for n = 1:Npts
        points[1, n] = x[n]
        points[2, n] = y[n]
        points[3, n] = z[n]
    end
    gtype = grid_type(eltype(cells))
    vtk_grid(gtype, filename, points, cells, args...; kwargs...)
end

# 2D version
vtk_grid(filename::AbstractString, x::AbstractVector{T},
         y::AbstractVector{T}, cells::CellVector, args...; kwargs...) where {T} =
    vtk_grid(filename, x, y, zero(x), cells, args...; kwargs...)

# 1D version
vtk_grid(filename::AbstractString, x::AbstractVector{T},
         cells::CellVector, args...; kwargs...) where T =
    vtk_grid(filename, x, zero(x), zero(x), cells, args...; kwargs...)

# Variant with 4-D Array (for "pseudo-unstructured" datasets, i.e., those that
# actually have a 3D structure) -- maybe this variant should be removed...
function vtk_grid(filename::AbstractString, points::AbstractArray{T,4},
                  cells::CellVector, args...; kwargs...) where T
    dim, Ni, Nj, Nk = size(points)
    points_r = reshape(points, (dim, Ni*Nj*Nk))
    gtype = grid_type(eltype(cells))
    vtk_grid(gtype, filename, points_r, cells, args...; kwargs...)
end